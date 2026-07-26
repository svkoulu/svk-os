#!/usr/bin/bash
# 40-desktop.sh — GNOME defaults, per-account app restrictions, school CA trust.
set -euo pipefail

echo "::group:: dconf defaults"
# Compiles every db under /etc/dconf/db/*.d into its binary db:
#   local  (files/os/etc/dconf/db/local.d/)  -> fleet-wide defaults, every account
#   kiosk  (files/os/etc/dconf/db/kiosk.d/)  -> kiosk defaults + LOCKS, read only by
#                                               accounts whose profile is `kiosk`
# The kiosk layer is its own db precisely because one image serves lab machines
# and staff laptops; see files/os/etc/dconf/profile/kiosk.
dconf update
echo "::endgroup::"

echo "::group:: Restrict admin-facing GNOME apps by group"
# There is no per-machine flavor any more, so the boundary is the ACCOUNT:
#
#   app                     admin   staff   opilas
#   gnome-disks              yes     no      no
#   ptyxis (Terminal)        yes     no      no
#   gnome-system-monitor     yes     no      no
#   gnome-tweaks             yes     no      no
#   firewall-config          yes     no      no
#   gnome-software           yes     yes     no
#
# Enforced with group ownership + mode 0750 on the binary: admin is in wheel,
# admin and staff are in svk-staff (usr/lib/sysusers.d/svk-admin.conf), opilas is
# in neither. Not uninstalled — udisksd and the rest of each stack stay intact for
# the desktop's own use, and admin needs the real thing for hands-on diagnostics.
#
# svk-staff must be referenced NUMERICALLY: sysusers creates it at first boot, so
# the name does not resolve in this build container. wheel is gid 10 everywhere.
#
# 481, not something in the 900s: Silverblue's dynamic allocator hands out system
# gids counting DOWN from 999 and has already reached 959, so the whole 959-999
# band is occupied (981 is `printadmin`, 980 is `power` — the first choice here
# collided with both). 100-499 is Fedora's soft-static band and 191-958 is
# completely empty in this base, so 481 has ~470 gids of headroom before the
# allocator could ever reach it.
SVK_STAFF_GID=481

# Assert it's still free. If the base image ever ships a package that takes this
# gid, systemd-sysusers silently allocates svk-staff a DIFFERENT one at first boot
# (it logs at debug level and falls back), leaving gnome-software group-owned by
# whatever package won — staff locked out, some unrelated group let in, and nothing
# reporting it. Fail the build instead.
if getent group "$SVK_STAFF_GID" >/dev/null 2>&1; then
    echo "ERROR: gid ${SVK_STAFF_GID} is taken in the base image by" \
         "'$(getent group "$SVK_STAFF_GID" | cut -d: -f1)'." >&2
    echo "       Pick a free gid and change it in BOTH this file and" >&2
    echo "       files/os/usr/lib/sysusers.d/svk-admin.conf." >&2
    exit 1
fi

# The .desktop files are KEPT (the old build deleted them). admin logs into the
# GUI and needs a launcher — with the terminal itself restricted there is no
# fallback way to start one. Hiding the icons from the accounts that can't run
# them is handled per-account by the NoDisplay stub sets built further down.
restrict() {
    local bin="$1" group="$2"
    [ -e "$bin" ] || { echo "  skip ${bin} (not in this image)"; return 0; }
    chgrp "$group" "$bin"
    chmod 0750 "$bin"
    echo "  restricted ${bin} -> group ${group}, mode 0750"
}

# Every entry is existence-guarded, so an app the base doesn't ship is skipped
# (loudly, in the build log) rather than silently mishandled. As of Silverblue 44
# gnome-tweaks and firewall-config are NOT in the base at all — they stay listed
# so that adding either to 10-packages.sh, or a base that starts shipping them,
# gets the restriction and the hidden launcher for free.
WHEEL_ONLY_APPS=(
    /usr/bin/gnome-disks           # Disks
    /usr/bin/ptyxis                # Terminal
    /usr/bin/gnome-system-monitor  # System Monitor
    /usr/bin/gnome-tweaks          # Tweaks           (not in Silverblue 44)
    /usr/bin/firewall-config       # Firewall         (not in Silverblue 44)
)
for bin in "${WHEEL_ONLY_APPS[@]}"; do
    restrict "$bin" wheel
done
restrict /usr/bin/gnome-software "$SVK_STAFF_GID"
echo "::endgroup::"

echo "::group:: Hidden-launcher sets (NoDisplay stubs, selected via XDG_DATA_DIRS)"
# Mode 0750 stops execution, but a visible icon that does nothing is a support
# call. Ship NoDisplay copies of the relevant .desktop files under
#   /usr/share/svk/hidden-apps/<set>/applications/
# and select a set per account by prepending that directory to XDG_DATA_DIRS in
# the account's ~/.config/environment.d/ (planted by the kickstart). Desktop-entry
# lookup is first-match-wins per id across XDG_DATA_DIRS, so a stub shadows
# /usr/share/applications/<id>.desktop for that account and nobody else.
#
#   wheel-only -> the five wheel-restricted apps.   Used by staff.
#   opilas     -> those five plus gnome-software.   Used by opilas.
#
# The content stays in /usr, so image updates propagate and adding an app to a set
# needs no change on any machine — only the one-line environment.d file is
# machine-local. Same shadowing technique as 2fd4c12 (reverted then only because
# the flatpak it masked did not exist).
#
# Desktop ids are DERIVED from the Exec= line, never hardcoded: Fedora renames
# these (gnome-terminal -> ptyxis, evince -> papers), and a stale hardcoded id
# would silently leave a launcher visible. A restricted binary with no matching
# desktop entry fails the build rather than degrading quietly.
stub_launchers() {
    local set_name="$1"; shift
    local dir="/usr/share/svk/hidden-apps/${set_name}/applications"
    mkdir -p "$dir"
    local bin base entry id found
    for bin in "$@"; do
        [ -e "$bin" ] || { echo "  skip ${bin} (not in this image)"; continue; }
        base="${bin##*/}"
        found=0
        for entry in $(grep -lE "^Exec=(/usr/bin/)?${base}([[:space:]]|$)" \
            /usr/share/applications/*.desktop 2>/dev/null || true); do
            id="${entry##*/}"
            # Body at column 0: <<- strips tabs only, and this file is space-indented.
            cat >"${dir}/${id}" <<EOF
[Desktop Entry]
# svk: shadows /usr/share/applications/${id} for accounts whose XDG_DATA_DIRS
# starts with this set. Generated by build/40-desktop.sh — do not edit in place.
Type=Application
Name=${base}
Exec=${bin}
NoDisplay=true
EOF
            echo "  ${set_name}: hiding ${id}"
            found=1
        done
        if [ "$found" -eq 0 ]; then
            echo "ERROR: ${bin} exists but no /usr/share/applications entry launches it —" >&2
            echo "       its launcher would stay visible. Fix the Exec= match here." >&2
            exit 1
        fi
    done
}

stub_launchers wheel-only "${WHEEL_ONLY_APPS[@]}"
stub_launchers opilas "${WHEEL_ONLY_APPS[@]}" /usr/bin/gnome-software
echo "::endgroup::"

echo "::group:: Lock the Wi-Fi connection profile, if one was provisioned"
# NM refuses a secrets-bearing profile more permissive than 0600, and git doesn't
# preserve that bit across clones/CI. No-op until the real (gitignored)
# .nmconnection is dropped in alongside the .example.
conn=/etc/NetworkManager/system-connections/svk-student-wifi.nmconnection
if [ -f "$conn" ]; then
    chmod 600 "$conn"
    chown root:root "$conn"
    echo "  locked ${conn}"
fi
echo "::endgroup::"

echo "::group:: School CA trust"
# Any *.crt dropped into files/os/etc/pki/ca-trust/source/anchors/ is trusted
# once the store is rebuilt here.
update-ca-trust
echo "::endgroup::"
