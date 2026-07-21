#!/usr/bin/bash
# 20-services.sh — systemd enablement + local (.local / mDNS) name resolution.
set -euo pipefail

echo "::group:: Enable services"
# Tailscale daemon + first-boot enrolment. Students disable tailscaled again in
# build.student.sh (they stay off the tailnet); the config decides who enrols.
systemctl enable tailscaled.service
systemctl enable svk-tailscale-enroll.service
# mDNS advertising (.local), key-only SSH, power-profile switching, and the
# first-boot hostname claim. All shipped to every desktop via files/base.
systemctl enable avahi-daemon.service
systemctl enable sshd.service
systemctl enable svk-power-profile.service
systemctl enable svk-claim-hostname.service
# First-boot TPM2 auto-unlock enrollment + on-screen LUKS recovery key. No-op on
# unencrypted installs (ConditionPathExists guards it); self-disables once enrolled.
systemctl enable svk-luks-tpm-enroll.service
# Image + flatpak auto-update. bootc-fetch-apply-updates.timer ships DISABLED
# upstream (opt-in) — every desktop flavor needs this explicitly, same as
# build.server.sh already does for svk-server. Per-flavor schedule comes from
# each image's own timer.d drop-in (files/{student,staff}/…); the ExecStart=
# override that drops --apply lives in files/base's service.d (applies to all
# three desktop flavors uniformly).
systemctl enable bootc-fetch-apply-updates.timer
systemctl enable svk-flatpak-update.timer
echo "::endgroup::"

echo "::group:: NSS mDNS — make .local names resolve"
# The fleet is addressed by <hostname>.local on the LAN (students never join the
# tailnet). nss-mdns provides the resolver; wire it into nsswitch (idempotent).
if ! grep -qE '^hosts:.*mdns' /etc/nsswitch.conf; then
    sed -i -E 's/^(hosts:[[:space:]]+).*/\1files mdns4_minimal [NOTFOUND=return] myhostname resolve [!UNAVAIL=return] dns/' \
        /etc/nsswitch.conf
fi
echo "::endgroup::"
