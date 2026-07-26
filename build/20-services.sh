#!/usr/bin/bash
# 20-services.sh — systemd enablement + local (.local / mDNS) name resolution.
set -euo pipefail

echo "::group:: Enable services"
# Tailscale daemon + first-boot enrolment. Whether a machine actually enrols is
# decided by TAILSCALE_ENROLL in /etc/svk/tailscale.conf (default "no"), not by
# the image — tailscaled is left enabled but never `up`s unless opted in.
systemctl enable tailscaled.service
systemctl enable svk-tailscale-enroll.service
# mDNS advertising (.local), key-only SSH, power-profile switching, and the
# first-boot hostname claim. All shipped to every desktop via files/os.
systemctl enable avahi-daemon.service
systemctl enable sshd.service
systemctl enable svk-power-profile.service
systemctl enable svk-claim-hostname.service
# First-boot TPM2 auto-unlock enrollment + on-screen LUKS recovery key. No-op on
# unencrypted installs (ConditionPathExists guards it); self-disables once enrolled.
systemctl enable svk-luks-tpm-enroll.service
# Image + flatpak auto-update. bootc-fetch-apply-updates.timer ships DISABLED
# upstream (opt-in), so enable it explicitly — same as build.server.sh does for
# svk-server. The weekly schedule and the ExecStart= override that drops --apply
# both come from files/os drop-ins next to each other.
systemctl enable bootc-fetch-apply-updates.timer
systemctl enable svk-flatpak-update.timer

# Kiosk units. Both ship enabled on every machine and both carry an
# ExecCondition that skips them cleanly when the `opilas` account doesn't exist,
# which is how a single image stays inert on a staff laptop:
#   reset-opilas-home       — creates/wipes /home/opilas from /etc/skel (the real
#                             trigger is GDM PostSession, this just makes it
#                             present, startable and run at boot)
#   svk-bluetooth-default-off — re-blocks the BT radio each boot on lab machines
systemctl enable reset-opilas-home.service
systemctl enable svk-bluetooth-default-off.service
echo "::endgroup::"

echo "::group:: NSS mDNS — make .local names resolve"
# The fleet is addressed by <hostname>.local on the LAN (lab machines never join the
# tailnet). nss-mdns provides the resolver; wire it into nsswitch (idempotent).
if ! grep -qE '^hosts:.*mdns' /etc/nsswitch.conf; then
    sed -i -E 's/^(hosts:[[:space:]]+).*/\1files mdns4_minimal [NOTFOUND=return] myhostname resolve [!UNAVAIL=return] dns/' \
        /etc/nsswitch.conf
fi
echo "::endgroup::"
