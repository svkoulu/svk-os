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

# The school's curated Flathub mirror (svk-flathub-sync.py on the server), as a
# SECOND, higher-priority remote. Flatpak tries the higher-priority remote
# first and falls through to the real flathub remote automatically for any ref
# the mirror doesn't have (a small, deliberately-curated subset) — so this is
# purely a speed-up, never a restriction. Staff browse it in GNOME Software;
# students are already locked out of Software installs via dconf
# (org/gnome/software allow-updates=false), so no separate gating is needed
# here regardless of what's in the mirror.
#
# Trust: reuse Flathub's OWN published signing key (extracted fresh from their
# .flatpakrepo, not hand-copied) rather than embedding a key blob in this repo
# — the mirror serves Flathub's commits verbatim, signatures and all.
if ! flatpak remote-list --system | grep -q '^svk-flathub-mirror'; then
    if repo_file="$(curl -fsSL --max-time 10 https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null)"; then
        gpg_key="$(printf '%s\n' "$repo_file" | awk '
            /^GPGKey=/ { sub(/^GPGKey=/, ""); printf "%s", $0; collecting=1; next }
            collecting && /^[A-Za-z]+=/ { exit }
            collecting { printf "%s", $0 }
        ')"
        keyfile="$(mktemp)"
        printf '%s' "$gpg_key" | base64 -d > "$keyfile" 2>/dev/null
        if [ -s "$keyfile" ]; then
            flatpak remote-add --if-not-exists --system --prio=2 \
                --gpg-import="$keyfile" \
                svk-flathub-mirror http://svk-server.local:8080/ 2>/dev/null || true
        fi
        rm -f "$keyfile"
    else
        echo "svk-flatpak-preinstall: svk-flathub-mirror unreachable; will retry next boot" >&2
    fi
fi

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
