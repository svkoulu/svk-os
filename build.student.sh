#!/usr/bin/bash
# build.student.sh — kiosk lockdown layered on svk-base for the student laptops.
set -euo pipefail

### opilas kiosk account #######################################################
# Declared via files/student/usr/lib/sysusers.d/svk-opilas.conf (created at boot,
# NOT baked into /etc/passwd — bootc lint requires this). opilas is not in wheel
# (no sudo) and SSH is closed to it (sshd AllowGroups wheel). Autologin lives in
# files/student/etc/gdm/custom.conf; GDM's autologin PAM stack ignores the
# (sysusers-locked) password. The home is created/reset from /etc/skel by
# reset-opilas-home.service.

### GNOME lockdown (dconf) #####################################################
# files/student ships the keyfile db + locks + a profile layering the system db
# under the user. Compile it into the binary db (base already compiled its layer).
dconf update

### Strip apps a kiosk shouldn't expose #######################################
# On the raw Silverblue base, Distrobox / Homebrew / input-remapper and the
# Bluefin Discourse/Documentation/System-Update launchers DON'T EXIST — so unlike
# the old `FROM bluefin` build there's nothing to strip there. What Silverblue
# DOES ship and a kiosk shouldn't: gnome-tour (welcome tour) and malcontent-control
# (parental-controls GUI). Remove the packages; their .desktop files go with them.
#
# NOTE: `malcontent` the LIBRARY stays installed (separate package that does NOT
# get pulled out with the GUI — verified) — it's the per-user app-visibility
# enforcement layer, kept in reserve for possible student flatpak allowlisting.
to_remove=()
for pkg in gnome-tour malcontent-control; do
    rpm -q "$pkg" >/dev/null 2>&1 && to_remove+=("$pkg")
done
[ ${#to_remove[@]} -gt 0 ] && dnf5 remove -y "${to_remove[@]}"

### Bluetooth off by default each boot ########################################
# The radio/daemon stay available (a student CAN switch it on for the session via
# Quick Settings); it just resets to off on the next boot.
systemctl enable svk-bluetooth-default-off.service

### Home reset on logout / boot ###############################################
systemctl enable reset-opilas-home.service

### Lock Wi-Fi to the one baked connection profile ############################
# NM refuses a secrets-bearing profile more permissive than 0600, and git doesn't
# preserve that bit across clones/CI. No-op until the real (gitignored)
# .nmconnection is provisioned alongside the .example.
conn=/etc/NetworkManager/system-connections/svk-student-wifi.nmconnection
# `if` (not `[ -f ] && …`): as the script's last statement the && form would return
# 1 when the file is absent and fail the build under `set -e`.
if [ -f "$conn" ]; then
    chmod 600 "$conn"
    chown root:root "$conn"
fi

# Tailscale: students stay OFF the tailnet, handled by TAILSCALE_ENROLL=no in
# /etc/svk/tailscale.conf (svk-tailscale-enroll.service no-ops) — tailscaled is
# left enabled but never `up`s. No action needed here.
