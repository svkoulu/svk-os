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

### Strip default Bluefin/GNOME apps a kiosk has no use for ##################
# gnome-tour (Tour), malcontent-control (Parental Controls) and input-remapper
# (Input Remapper) are upstream RPM packages (see ublue-os/bluefin's
# build_files/base/04-packages.sh and Fedora Workstation's default set) —
# remove idempotently like the install loop above. Community/Documentation/
# System Update are plain .desktop files baked in by projectbluefin/common
# (not RPM-owned, so `rm` instead of override): they point at Discourse, a
# bundled PDF, and `ujust update` — none relevant to a kiosk whose updates
# come from the weekly CI rebuild, not per-machine action.
TO_REMOVE=(gnome-tour malcontent-control input-remapper)
present=()
for pkg in "${TO_REMOVE[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 && present+=("$pkg")
done
[ ${#present[@]} -gt 0 ] && rpm-ostree override remove "${present[@]}"

rm -f /usr/share/applications/discourse.desktop \
      /usr/share/applications/documentation.desktop \
      /usr/share/applications/system-update.desktop

### Bluetooth off by default ##################################################
# rfkill-block bluetooth on every boot (files/student/etc/systemd/system/
# svk-bluetooth-default-off.service). The radio/daemon stay available so a
# student CAN still switch it on for the session via Quick Settings; it just
# resets to off on the next boot instead of a prior student's choice sticking.
systemctl enable svk-bluetooth-default-off.service

### Enable the home-reset unit ################################################
systemctl enable reset-opilas-home.service

### Lock Wi-Fi to the one baked connection profile ############################
# The profile itself (if the admin has provisioned the real, gitignored
# .nmconnection file — see the .example alongside it) needs 0600 root:root;
# git doesn't reliably preserve that bit across clones/CI checkouts. NM
# refuses to use a connection file with secrets that's more permissive than
# that. No-op if the real file hasn't been provisioned yet.
conn=/etc/NetworkManager/system-connections/svk-student-wifi.nmconnection
[ -f "$conn" ] && chmod 600 "$conn" && chown root:root "$conn"

### Reset target logout->reset##################################################
# The reset itself is driven by GDM PostSession (see files/student). Nothing to
# enable beyond the service above.
