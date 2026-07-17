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
echo "::endgroup::"

echo "::group:: NSS mDNS — make .local names resolve"
# The fleet is addressed by <hostname>.local on the LAN (students never join the
# tailnet). nss-mdns provides the resolver; wire it into nsswitch (idempotent).
if ! grep -qE '^hosts:.*mdns' /etc/nsswitch.conf; then
    sed -i -E 's/^(hosts:[[:space:]]+).*/\1files mdns4_minimal [NOTFOUND=return] myhostname resolve [!UNAVAIL=return] dns/' \
        /etc/nsswitch.conf
fi
echo "::endgroup::"
