# svk-check — a boot-time/periodic health assertion service

Status: **deferred idea, not scheduled.** Noted 2026-07-26 while comparing svk
against openSUSE Aeon (see `../../../aeon-os/NOTES.md`).

## Where the idea came from

Aeon ships `aeon-check.service`: a boot-time service that detects and *repairs*
known-broken states on already-installed machines (masking a unit that shipped
enabled by mistake, adding a setting an older install is missing). It exists
because on a package-based OS, machines drift and old installs carry old
mistakes.

bootc doesn't need the repair half — a broken state is fixed by shipping a new
image, and every machine converges on it. **But we have no equivalent of the
detection half**, and that is a real gap: CLAUDE.md names "the pipeline silently
stops and the fleet silently stops getting updates" as the risk driving most of
the design, and today nothing on the *machine* side would notice.

So: port the idea, invert the action. **Report drift, never repair it.**

## What exists already

`custom/ujust/svk-maintenance.just` has `check-drift`, which diffs `/usr/etc`
against `/etc`. It is manual, on-demand, and only covers config drift. The gaps
are that nothing runs on a schedule and nothing reports.

## Proposed shape

A `svk-check.service` oneshot + timer shipped in `files/base/`, plus a
`ujust check-health` front-end onto the same script (mirroring how `check-drift`
works today). Assertions worth making:

- bootc origin points at the expected registry ref, and signature enforcement is
  actually active (`/etc/containers/policy.json` + `registries.d` intact).
- `cosign.pub` on disk matches the expected fingerprint.
- **Last successful `bootc upgrade` was within N days.** This is the one that
  closes the "fleet silently stops updating" risk from the machine side; N should
  be derived from the flavor's cadence (student monthly, staff weekly — see
  `20260719-2126-fleet-update-cadence.md`) with generous slack.
- LUKS TPM2 enrollment present and the recovery-key slot still exists.
- Installed system flatpak set matches `flatpaks/*.list`.
- dconf lockdown db compiled and non-empty (a silently empty `local` db means the
  kiosk lockdown is not in effect).
- tailscale state matches `/etc/svk/tailscale.conf` (enrolled when `ENROLL=yes`).

Output goes to the journal at a level that's greppable over admin SSH. A push
channel (Tailscale-reachable endpoint, or the server collecting reports) is a
possible later extension — the local assertion is the valuable part.

## Why this is a prerequisite for cosign key rotation

Rotating the signing key requires publishing a dual-trust image and confirming
**every** machine has taken it before signing with the new key alone. A machine
that misses that window rejects everything afterwards and needs a USB reinstall
or physical console access. That confirmation step needs per-machine state — the
"last successful upgrade" assertion above is what makes it possible.

See the *Signing key* section in `README.md` for the rotation procedure itself.
