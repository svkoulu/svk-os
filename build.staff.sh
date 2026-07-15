#!/usr/bin/bash
# build.staff.sh — staff desktop. Almost nothing on top of school-base: normal
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

### Pre-installed staff software (optional) ###################################
# System flatpaks / packages every staff member should have. Placeholder:
#
# flatpak install --system --noninteractive flathub <<ADD STAFF FLATPAKS HERE>>
#
# Per-person apps are NOT baked here — staff use `flatpak install --user`.
