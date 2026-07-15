#!/usr/bin/bash
# build.server.sh — pull-through registry cache host + hostname dispenser.
set -euo pipefail

### Tailscale #################################################################
# uCore can layer tailscale. Installed only — enrolls at provision time with
# tag:svk-admin (files/server/etc/school/tailscale-tag). No key baked in.
rpm-ostree install tailscale || true   # may already be present in uCore
systemctl enable tailscaled.service

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

### Cleanup ###################################################################
rpm-ostree cleanup -m || true
