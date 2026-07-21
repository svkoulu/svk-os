# vim: set ft=make :
# svk-update.just — manual override + status for the scheduled bootc-image and
# flatpak update units (files/base/etc/systemd/system/{bootc-fetch-apply-updates,
# svk-flatpak-update}.*). See tasks/todo/…-fleet-update-cadence.md.

# Reuses the exact same units/wrapper scripts/logging as the scheduled timer,
# just run on demand. Stages only — does NOT force a reboot.
# Update image + flatpaks right now (no forced reboot).
[group('Update')]
update-now:
    #!/usr/bin/bash
    set -euo pipefail
    echo "Staging image + flatpak updates now (no forced reboot)..."
    sudo systemctl start bootc-fetch-apply-updates.service
    sudo systemctl start svk-flatpak-update.service
    echo "Done. Run 'ujust update-status' to see the result."

# Deliberately separate from update-now and confirmation-gated: for a genuine
# "fix this right now" situation, not routine use — an unattended scheduled
# reboot is exactly what the normal per-flavor cadence avoids.
# Update AND apply immediately — reboots now if an image update is found.
[group('Update')]
update-apply-now:
    #!/usr/bin/bash
    set -euo pipefail
    echo "This updates flatpaks (no reboot), then the image — the machine may"
    echo "reboot IMMEDIATELY and without further warning if an image update is found."
    read -r -p "Proceed? [y/N] " ans
    case "${ans,,}" in
        y|yes) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
    sudo /usr/libexec/svk/svk-update-flatpak || true
    # bootc upgrade --apply may terminate this shell via reboot before a wrapper
    # script could log an "after" state — record the trigger itself instead.
    printf '%s\timage\tmanual-apply-now\t(reboot pending)\ttriggered\t-\n' \
        "$(date -u +%FT%TZ)" | sudo tee -a /var/log/svk/update.log >/dev/null
    echo "Applying image update now..."
    sudo bootc upgrade --apply --quiet

# No journalctl/systemctl syntax to remember.
# Show recent update history and the scheduled timers' state.
[group('Update')]
update-status:
    #!/usr/bin/bash
    set -euo pipefail
    echo "== Last 10 update log entries =="
    if sudo test -s /var/log/svk/update.log; then
        sudo tail -n 10 /var/log/svk/update.log | column -t -s $'\t'
    else
        echo "(no runs recorded yet)"
    fi
    echo
    echo "== Update timers =="
    systemctl list-timers bootc-fetch-apply-updates.timer svk-flatpak-update.timer --no-pager
