#!/usr/bin/bash
# build.server.sh — pull-through registry cache host + hostname dispenser.
set -euo pipefail

### Baseline CLI toolbox #####################################################
# Same handy tools as the desktops (build.base.sh). uCore is minimal, so most
# of these are genuinely missing here. fd-find provides /usr/bin/fd.
rpm-ostree install htop curl wget ncdu fd-find || true

### Tailscale #################################################################
# uCore can layer tailscale. Installed only — enrolls at provision time with
# tag:svk-admin (files/server/etc/svk/tailscale.conf). No key baked in.
rpm-ostree install tailscale || true   # may already be present in uCore
systemctl enable tailscaled.service

### Local name resolution — mDNS / .local ####################################
# The server must answer to `svk-server.local` for the whole LAN, including the
# student machines that are not on the tailnet. Avahi advertises it (its system
# hostname is pinned to svk-server via /etc/hostname in server.bu); nss-mdns
# lets the server resolve the desktops' svk-*.local names to SSH back into them.
rpm-ostree install avahi nss-mdns || true
systemctl enable avahi-daemon.service
if ! grep -qE '^hosts:.*mdns' /etc/nsswitch.conf; then
    sed -i -E 's/^(hosts:[[:space:]]+).*/\1files mdns4_minimal [NOTFOUND=return] myhostname resolve [!UNAVAIL=return] dns/' /etc/nsswitch.conf
fi

### Firewall — open the LAN-facing services ##################################
# uCore's default zone allows ssh + cockpit but not our extra ports. Open them
# at build time with the offline tool (firewalld isn't running during a build).
# mdns  = 5353/udp (.local),  registry cache = 5000/tcp,  dispenser = 8765/tcp.
if command -v firewall-offline-cmd >/dev/null 2>&1; then
    firewall-offline-cmd --add-service=mdns        || true
    firewall-offline-cmd --add-port=5000/tcp       || true
    firewall-offline-cmd --add-port=8765/tcp       || true
fi

### Cockpit ###################################################################
# Already present in uCore; just make sure the socket comes up on boot.
systemctl enable cockpit.socket

### Registry cache ###########################################################
# The pull-through cache runs as a Podman quadlet (registry.container, copied in
# via files/server). Quadlet-generated units can't be `systemctl enable`d at
# build time (the generator runs at boot), so there is nothing to enable here —
# the [Install] section in registry.container handles it on first boot.

### Hostname dispenser #######################################################
# Socket-activated; enabling the .socket is enough.
systemctl enable hostname-dispenser.socket

### Automatic updates ########################################################
# uCore doesn't auto-update by default. Drive OS updates through bootc's own
# timer on our randomized schedule (drop-in: bootc-fetch-apply-updates.timer.d/
# 10-svk-randomize.conf). One server, but keep it current like the desktops.
systemctl enable bootc-fetch-apply-updates.timer

### Cleanup ###################################################################
rpm-ostree cleanup -m || true
