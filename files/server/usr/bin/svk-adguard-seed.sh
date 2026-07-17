#!/usr/bin/bash
# svk-adguard-seed.sh — seed AdGuard Home's config onto the persistent volume
# on first run only, then get out of the way (AdGuard Home owns the file after
# that, same pattern as hostname-pool.example -> hostname-dispenser.sh).
#
# Runs as svk-adguard-seed.service, ordered Before= the quadlet-generated
# adguard-home.service (see adguard-home.container's [Unit] section).
set -euo pipefail

VOLUME_NAME=systemd-adguard-home
SEED=/usr/share/svk/adguardhome.yaml.example

podman volume create --ignore "$VOLUME_NAME" >/dev/null
mountpoint="$(podman volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}')"

mkdir -p "$mountpoint/conf" "$mountpoint/work"
[ -f "$mountpoint/conf/AdGuardHome.yaml" ] || cp "$SEED" "$mountpoint/conf/AdGuardHome.yaml"
