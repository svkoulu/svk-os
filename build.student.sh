#!/usr/bin/bash
# build.student.sh — kiosk lockdown baked into school-student.
set -euo pipefail

### The passwordless `student` account ########################################
# Autologin target. `passwd -d` leaves the account with an empty password;
# combined with GDM autologin the student never sees a password prompt. It is
# NOT in `wheel`, so it cannot sudo.
#
# `-M` (no home at build): in bootc, /home -> /var/home is runtime state and is
# NOT captured in the image, so a build-time home would just vanish. The home is
# created + populated from /etc/skel at boot by reset-student-home.service (which
# also runs before the display manager). Only the /etc/passwd entry needs to be
# baked, and that lives in /etc which IS persisted.
if ! id student &>/dev/null; then
    useradd -M --shell /bin/bash --comment "Kiosk student" student
fi
passwd -d student

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

### System Flatpaks only ######################################################
# Students get a fixed, system-wide app set (no --user installs). Install the
# system flatpaks here. Flatpak needs a remote; flathub is usually already
# configured on Bluefin. Placeholder — add the exact app IDs:
#
# flatpak install --system --noninteractive flathub \
#     org.mozilla.firefox \
#     org.libreoffice.LibreOffice \
#     <<ADD STUDENT FLATPAKS HERE>>
#
# NOTE: `flatpak install` at build time can be flaky in CI (needs network + a
# configured remote). If it fails the build, prefer shipping a
# /etc/flatpak/... preinstall drop-in instead. Left commented on purpose.

### Enable the home-reset unit ################################################
systemctl enable reset-student-home.service

### Reset target logout->reset##################################################
# The reset itself is driven by GDM PostSession (see files/student). Nothing to
# enable beyond the service above.
