#!/usr/bin/bash
# school-claim-hostname.sh — claim a fleet hostname on first boot.
#
# WHY THIS EXISTS
#   Every laptop rolls off the same image, so they all boot with the same
#   hostname. Inside Tailscale that means MagicDNS names collide (Tailscale
#   would auto-suffix them -1, -2, ... in join order, which is unstable and
#   meaningless). This claims a *stable, friendly* name from a pool the server
#   hands out, so machines resolve as e.g. svk-student-03 on the tailnet.
#
# HOW
#   Talk a dead-simple line protocol to the server's dispenser:
#     ->  send our machine-id
#     <-  receive the assigned hostname
#   The dispenser is idempotent (same machine-id always gets the same name), so
#   retries and re-runs are safe.
#
#   If the server can't be reached we DO NOT block provisioning — we fall back
#   to a deterministic name derived from the machine-id. Tailscale still
#   deduplicates, so the fleet stays usable; you just get a less friendly name.
set -euo pipefail

# The dispenser runs on the server, which is also the registry cache host.
DISPENSER_HOST="<<REGISTRY_CACHE_HOST>>"
DISPENSER_PORT=8765
STAMP=/var/lib/school/.hostname-claimed

mkdir -p "$(dirname "$STAMP")"
[ -e "$STAMP" ] && exit 0   # already claimed; nothing to do

MACHINE_ID="$(cat /etc/machine-id)"

claim_from_server() {
    # bash's /dev/tcp gives us a socket without pulling in netcat.
    exec 3<>"/dev/tcp/${DISPENSER_HOST}/${DISPENSER_PORT}" || return 1
    printf '%s\n' "$MACHINE_ID" >&3
    local name
    read -r -t 10 name <&3 || { exec 3>&-; return 1; }
    exec 3>&-
    # Basic sanity: dispenser returns a bare hostname label.
    [[ "$name" =~ ^[a-z0-9-]+$ ]] || return 1
    printf '%s' "$name"
}

NAME=""
for attempt in 1 2 3 4 5; do
    if NAME="$(claim_from_server)"; then
        break
    fi
    NAME=""
    sleep 5
done

if [ -z "$NAME" ]; then
    # Fallback: deterministic short name from the machine-id. Not pretty, but
    # unique and stable. Tag prefix from the tailscale-tag file if present.
    tag="$(sed 's/^tag:svk-//; s/^tag://' /etc/school/tailscale-tag 2>/dev/null || echo node)"
    NAME="svk-${tag:-node}-${MACHINE_ID:0:8}"
fi

hostnamectl set-hostname "$NAME"
touch "$STAMP"
echo "Claimed fleet hostname: $NAME"
