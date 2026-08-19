# svk-server duplicates a box `../infra` already runs at the school

Status: **open question, not a decision.** Written 2026-08-19 after reading
`../infra`. Needs the operator's call before any code moves.

## The overlap

`../svk-server` is a bootc image (FROM uCore, Ignition-installed) providing four
services for the school: a pull-through registry cache, a hostname dispenser, a
curated Flathub mirror, and AdGuard Home DNS. It was split out of this repo on
2026-07-27 and, by its own README, **has not been built or tested since**.

Meanwhile `../infra` — the servers project — already has a box named **`svk`**,
at the school (`BOX_LOCATION=svk`), installed on real hardware, on the tailnet,
converged by Ansible, and already running:

- `adguard-home` as a quadlet workload (`boxes/svk/workloads/adguard-home/`),
  deployed and verified 2026-08-10
- `winfleet-hub`, the receiver for the school's Windows machines

So AdGuard Home for this school is specified twice, in two repos, with two
different delivery mechanisms — and one of the two is running.

## The case for retiring svk-server

- Two of its four services (registry cache, Flathub mirror) are **plain OCI
  containers**, which is exactly infra's default workload tier. No escalation, no
  new machinery: a `workload.yaml` each.
- AdGuard already exists there, deployed, with a runbook and a per-site DNS
  handover procedure.
- It deletes an entire second image, its signing pipeline, its Ignition install
  path and a repo that currently has one commit and no tests.
- The services inherit infra's greenboot, monitoring, `just deploy`, and the
  install runbooks — all of which svk-server would otherwise have to grow.
- The school box is *already there*. Standing up a second server at the same site
  to run four containers is hard to justify.

## What has to be checked before deciding

1. **The hostname dispenser is socket-activated** and hands out fleet hostnames
   from a pool. It is the one service that is not a stock container; it needs a
   home (a small quadlet with repo-owned code, like infra's `blockpage` and
   `winfleet-hub`, which is a pattern they already have).
2. **`svk-server.local` is baked into this image** — the ghcr mirror drop-in
   (`files/os/etc/containers/registries.conf.d/010-ghcr-mirror.conf`), the DNS
   profile, `svk-claim-hostname`, and the server's authorized key. If the
   services move to the infra box, either that box answers to `svk-server.local`
   (mDNS alias / CNAME) or those references change. This is the concrete piece of
   work, and it is small.
3. **Does the infra box have the disk** for a registry cache and a Flathub mirror?
   Multi-GB and growing; a laptop-class box may not.
4. **Blast radius.** Today a broken school server costs the school its cache and
   its DNS. Under the merge it is also the box carrying `winfleet-hub` and the
   site's monitoring. That is not necessarily wrong — it is one site, one box —
   but it should be a decision rather than an accident.

## The reverse direction, while we are here

infra's own checklist still has **"cosign signing at promote time + `policy.json`
verification on boxes"** unchecked. That is finished here: the composite action
(`.github/actions/build-image/`), the `registries.d` + `policy.json` enforcement
baked into every image, the pinned cosign v2 line and the reason for it, and the
rotation procedure in `README.md`. It should be lifted across rather than
rewritten — this repo's signing is the one part of it that is genuinely ahead.

## Outcomes

- [ ] Operator decision: retire `svk-server`, or keep two servers and say why
- [ ] If retired: `workload.yaml` for registry cache, Flathub mirror, hostname
      dispenser; `svk-server.local` resolved on the infra box; `../svk-server`
      archived with a pointer
- [ ] Either way: infra takes this repo's signing machinery
