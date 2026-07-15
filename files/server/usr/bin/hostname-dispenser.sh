#!/usr/bin/bash
# hostname-dispenser.sh — hand out one fleet hostname per machine, from a pool.
#
# Runs once per incoming connection (socket-activated, Accept=yes). Protocol:
#   stdin   <-  the client's machine-id (one line)
#   stdout  ->  the assigned hostname   (one line)
#
# Idempotent: the same machine-id always gets the same name, so a client that
# retries (or re-provisions from the same disk) keeps its name and we don't burn
# pool entries. State lives under /var/lib/school on the data volume, so it
# survives image updates (bootc only replaces /usr, not /var).
#
# The pool itself is defined LATER — /var/lib/school/hostname-pool. An example
# ships at /usr/share/school/hostname-pool.example; on first run we seed the
# real file from it if it's missing.
set -euo pipefail

STATE_DIR=/var/lib/school
POOL="${STATE_DIR}/hostname-pool"
ASSIGN="${STATE_DIR}/hostname-assignments"
SEED=/usr/share/school/hostname-pool.example
LOCK="${STATE_DIR}/.dispenser.lock"

mkdir -p "$STATE_DIR"
[ -f "$POOL" ]   || cp "$SEED" "$POOL"
[ -f "$ASSIGN" ] || : > "$ASSIGN"

# Read the requesting machine-id (trim whitespace/CR, keep it sane).
read -r machine_id || exit 0
machine_id="${machine_id//[$'\r\n\t ']/}"
[[ "$machine_id" =~ ^[a-f0-9]{8,}$ ]] || { echo "ERR-bad-machine-id"; exit 0; }

# Serialize the whole read-modify-write; connections are rare and tiny.
exec 9>"$LOCK"
flock 9

# Already assigned? Return the same name.
existing="$(awk -v id="$machine_id" '$1==id {print $2; exit}' "$ASSIGN")"
if [ -n "$existing" ]; then
    echo "$existing"
    exit 0
fi

# Otherwise take the first pool name that isn't handed out yet. Skip blanks and
# '#' comments in the pool file.
while read -r candidate; do
    candidate="${candidate%%#*}"; candidate="${candidate//[$'\r\n\t ']/}"
    [ -z "$candidate" ] && continue
    if ! awk -v n="$candidate" '$2==n {found=1} END{exit !found}' "$ASSIGN"; then
        printf '%s\t%s\n' "$machine_id" "$candidate" >> "$ASSIGN"
        echo "$candidate"
        exit 0
    fi
done < "$POOL"

# Pool exhausted — tell the client, which then falls back to a machine-id name.
echo "ERR-pool-empty"
