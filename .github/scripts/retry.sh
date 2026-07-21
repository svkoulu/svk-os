#!/usr/bin/env bash
# Retry a command, but ONLY when it failed for a transient network/registry reason.
#
# Why not a blind retry: the builds here are long (dnf + full image assembly) and end
# in `bootc container lint --fatal-warnings`. Re-running a genuine failure (a bad
# package name, a lint error) burns 20+ minutes of CI per attempt and delays the
# signal we actually want to see. So the command's output is scanned, and a retry only
# happens on the known-flaky signatures: half-finished blob reads from quay/GHCR CDNs,
# TLS/connection resets, 5xx from the registry, dnf mirror hiccups.
#
# Usage: retry.sh <attempts> <command> [args...]
# Env:   RETRY_DELAY  seconds before the 2nd attempt (doubles each time; default 15)
set -uo pipefail

attempts="${1:?usage: retry.sh <attempts> <command> [args...]}"
shift
delay="${RETRY_DELAY:-15}"

# Signatures of "the network blinked", not "your build is broken".
transient='unexpected EOF|connection reset|connection refused|broken pipe|TLS handshake timeout|i/o timeout|Client\.Timeout|no such host|temporary failure|Temporary failure|EOF$|error pinging|received unexpected HTTP status: 5[0-9][0-9]|StatusCode=5[0-9][0-9]|502 Bad Gateway|503 Service|504 Gateway|too many requests|TOOMANYREQUESTS|Curl error|Failed to download|Cannot download|error reading from server|http2: (client|server) connection'

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

for (( i = 1; i <= attempts; i++ )); do
  # Tee so the step log still shows everything live, while we keep a copy to classify.
  "$@" 2>&1 | tee "${log}"
  rc="${PIPESTATUS[0]}"
  [ "${rc}" -eq 0 ] && exit 0

  if [ "${i}" -ge "${attempts}" ]; then
    echo "::error::failed after ${i} attempt(s) (exit ${rc}): $*"
    exit "${rc}"
  fi

  if ! grep -Eq "${transient}" "${log}"; then
    echo "::notice::failure does not look transient (exit ${rc}); not retrying: $*"
    exit "${rc}"
  fi

  echo "::warning::transient failure on attempt ${i}/${attempts} (exit ${rc}); retrying in ${delay}s: $*"
  sleep "${delay}"
  delay=$(( delay * 2 ))
done
