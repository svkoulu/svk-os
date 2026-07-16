#!/usr/bin/bash
# build.staff.sh — staff desktop. Almost nothing on top of svk-base: normal
# login, no kiosk, no skel reset. Staff manage their own apps via Flatpak
# `--user`, which persists across image updates.
set -euo pipefail

### Strip Distrobox & Homebrew ################################################
# Requirement: no Distrobox or Homebrew on staff machines either.
rm -f /usr/bin/distrobox* /usr/bin/brew || true
rm -rf /usr/share/ublue-os/homebrew || true
for unit in brew-setup.service brew-update.service brew-update.timer \
            brew-upgrade.service brew-upgrade.timer; do
    systemctl mask "$unit" 2>/dev/null || true
done

### Pre-installed staff software ##############################################
# The shared fleet apps (Firefox, LibreOffice, VLC, GIMP, video tools) come from
# /etc/svk/flatpaks.list via svk-flatpak-preinstall.service (build.base.sh). For
# staff-only extras, drop files/staff/etc/svk/flatpaks.list.d/*.list. Per-person
# apps are still installed by staff themselves with `flatpak install --user`.
