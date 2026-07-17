#!/usr/bin/bash
# svk-tailscale-enroll.sh — first-boot Tailscale enrollment for desktops.
#
# Reads the auth key from the PROVISIONING USB — a filesystem labelled SVK-PROV
# holding a plain-text file "tailscale-authkey" — and runs `tailscale up` with
# the tag from /etc/svk/tailscale.conf. Whether we enroll at all is
# TAILSCALE_ENROLL in that file: staff = yes, students = no. Auth keys are NEVER
# baked into an image; they ride the USB and are read once here.
#
# enroll=no / no USB / no key  =>  log and exit 0. Enrollment must never block a
# machine from finishing first boot; you can always `tailscale up` by hand.
set -euo pipefail

CONF=/etc/svk/tailscale.conf
STAMP=/var/lib/svk/.tailscale-enrolled
USB_LABEL=SVK-PROV
KEY_FILE=tailscale-authkey

[ -e "$STAMP" ] && exit 0
[ -r "$CONF" ] || { echo "tailscale-enroll: no $CONF; skipping"; exit 0; }
# shellcheck disable=SC1090
. "$CONF"

if [ "${TAILSCALE_ENROLL:-no}" != "yes" ]; then
    echo "tailscale-enroll: disabled for this image (TAILSCALE_ENROLL=${TAILSCALE_ENROLL:-no})"
    exit 0
fi

dev="$(findfs "LABEL=$USB_LABEL" 2>/dev/null || true)"
if [ -z "$dev" ]; then
    echo "tailscale-enroll: no $USB_LABEL media found; enroll by hand later" >&2
    exit 0
fi

mnt="$(mktemp -d)"
cleanup() { umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
mount -o ro,nosuid,nodev "$dev" "$mnt"

key="$(tr -d '[:space:]' < "$mnt/$KEY_FILE" 2>/dev/null || true)"
if [ -z "$key" ]; then
    echo "tailscale-enroll: $KEY_FILE not found on $USB_LABEL; skipping" >&2
    exit 0
fi

# tailscaled must be running to accept `up` (staff images keep it enabled).
systemctl start tailscaled.service 2>/dev/null || true

tag="${TAILSCALE_TAG:-tag:svk-node}"
if tailscale up --authkey "$key" --advertise-tags "$tag"; then
    mkdir -p "$(dirname "$STAMP")"
    touch "$STAMP"
    echo "tailscale-enroll: up as $tag"
else
    echo "tailscale-enroll: 'tailscale up' failed; will retry next boot" >&2
    exit 1
fi
