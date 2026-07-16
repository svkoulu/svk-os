#!/usr/bin/bash
# build.student.sh — kiosk lockdown baked into svk-student.
set -euo pipefail

### The passwordless `opilas` account #########################################
# Autologin target (opilas = "student"). `passwd -d` leaves the account with an
# empty password; combined with GDM autologin opilas never sees a password
# prompt. It is NOT in `wheel`, so it cannot sudo, and SSH is closed to it
# (10-svk-hardening.conf allows only group wheel).
#
# `-M` (no home at build): in bootc, /home -> /var/home is runtime state and is
# NOT captured in the image, so a build-time home would just vanish. The home is
# created + populated from /etc/skel at boot by reset-opilas-home.service (which
# also runs before the display manager). Only the /etc/passwd entry needs to be
# baked, and that lives in /etc which IS persisted.
if ! id opilas &>/dev/null; then
    useradd -M --shell /bin/bash --comment "Kiosk student (opilas)" opilas
fi
passwd -d opilas

### No Tailscale on students ##################################################
# Tailscale's free tier caps the tailnet at ~50 devices, and the student laptops
# are the bulk of the fleet — so they stay OFF the tailnet. base enabled
# tailscaled; undo that here. Students reach the cache/dispenser and are reached
# by the server purely over the LAN (mDNS .local + SSH). The config is kept:
# /etc/svk/tailscale.conf has TAILSCALE_ENROLL=no (so the base enrollment service
# no-ops) and the tag, which svk-claim-hostname.sh reads for svk-student-* names.
# systemctl disable tailscaled.service 2>/dev/null || true

### GNOME lockdown (dconf) ####################################################
# files/student ships the keyfile db + locks + a profile that layers the
# system db under the user. Compile it into the binary db now.
dconf update

### Strip Distrobox & Homebrew ################################################
# Bluefin ships both; a kiosk must not have container/pkg escape hatches.
# Remove the binaries and mask the setup units so nothing re-provisions them.
rm -f /usr/bin/distrobox* /usr/bin/brew || true
rm -rf /usr/share/ublue-os/homebrew || true
for unit in brew-setup.service brew-update.service brew-update.timer \
            brew-upgrade.service brew-upgrade.timer; do
    systemctl mask "$unit" 2>/dev/null || true
done

### System Flatpaks ###########################################################
# The fleet app set (Firefox, LibreOffice, VLC, GIMP, the video tools) is shipped
# fleet-wide via /etc/svk/flatpaks.list and installed on first boot by
# svk-flatpak-preinstall.service (enabled in build.base.sh) — students get them
# system-wide, no --user installs. To give students EXTRA apps beyond the shared
# list, drop files/student/etc/svk/flatpaks.list.d/*.list (the service reads it).

### Enable the home-reset unit ################################################
systemctl enable reset-opilas-home.service

### Reset target logout->reset##################################################
# The reset itself is driven by GDM PostSession (see files/student). Nothing to
# enable beyond the service above.
