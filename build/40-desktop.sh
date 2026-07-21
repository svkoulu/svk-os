#!/usr/bin/bash
# 40-desktop.sh — GNOME defaults, admin-app lockdown, school CA trust.
set -euo pipefail

echo "::group:: dconf defaults"
# Compile files/base/etc/dconf/db/local.d/00-svk-desktop into the binary db.
# svk-student runs `dconf update` again after adding its lockdown layer.
dconf update
echo "::endgroup::"

echo "::group:: Lock admin-facing GNOME apps (root-only, not uninstalled)"
# chmod 700 the binary + remove the .desktop so neither `staff` nor `opilas` can
# launch these, while `admin` can still reach one via sudo for hands-on diagnostics.
# Existence-guarded: an app the raw Silverblue base doesn't ship just no-ops.
#
# Disks (gnome-disk-utility, an RPM Silverblue ships) is deliberately NOT here:
# staff need it for USB sticks and disk health, so it's restricted in
# build.student.sh instead. There is no Disks flatpak on Flathub to install as a
# substitute — upstream never published one.
RESTRICT_APPS=(
    "/usr/bin/gnome-tweaks:org.gnome.tweaks.desktop"   # Tweaks
    "/usr/bin/ptyxis:org.gnome.Ptyxis.desktop"         # Terminal
    "/usr/bin/firewall-config:firewall-config.desktop" # Firewall
)
for entry in "${RESTRICT_APPS[@]}"; do
    bin="${entry%%:*}"; desktop="${entry##*:}"
    [ -e "$bin" ] && chmod 700 "$bin"
    rm -f "/usr/share/applications/$desktop"
done
echo "::endgroup::"

echo "::group:: School CA trust"
# Any *.crt dropped into files/base/etc/pki/ca-trust/source/anchors/ is trusted
# once the store is rebuilt here.
update-ca-trust
echo "::endgroup::"
