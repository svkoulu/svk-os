#!/usr/bin/bash
# svk-flatpak-preinstall.sh — install the fleet's system Flatpaks from a list.
#
# WHY A RUNTIME SERVICE, NOT A BUILD STEP
#   `flatpak install` during the image build needs network + a configured remote
#   inside CI, which is flaky and fails the whole build. Instead we ship the LIST
#   in the image and install here, on first boot, when the machine has network.
#   (This is the reliable form of the "preinstall drop-in" idea.)
#
# Idempotent: only genuinely-missing apps are installed, so it's safe to re-run
# every boot and it picks up new entries added to the list in a later image.
set -euo pipefail

# The shared fleet list, plus any per-image extras dropped in flatpaks.list.d/.
shopt -s nullglob
LISTS=(/etc/svk/flatpaks.list /etc/svk/flatpaks.list.d/*.list)
[ ${#LISTS[@]} -gt 0 ] || exit 0

# Flathub is normally already configured on Bluefin; make sure, non-fatally.
flatpak remote-add --if-not-exists --system \
    flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

rc=0
for list in "${LISTS[@]}"; do
    [ -f "$list" ] || continue
    while read -r line; do
        app="${line%%#*}"                      # strip trailing comment
        app="${app//[[:space:]]/}"             # strip all whitespace
        [ -z "$app" ] && continue
        flatpak info --system "$app" >/dev/null 2>&1 && continue   # already present
        if ! flatpak install --system --noninteractive --or-update flathub "$app"; then
            echo "svk-flatpak-preinstall: failed to install $app" >&2
            rc=1
        fi
    done < "$list"
done

# Don't hard-fail the boot on a single flaky download; the service re-runs next
# boot and installs whatever is still missing.
exit "$rc"
