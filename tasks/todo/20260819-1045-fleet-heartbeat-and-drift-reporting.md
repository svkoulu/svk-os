# Fleet heartbeat + update-staleness reporting

Status: **not started.** Written 2026-08-19. Borrowed from `../infra`
(ADR 0025 "monitoring is two independent paths", `os/files/usr/libexec/infra/hc-ping`,
`update-staleness`). Closely related to `…-svk-check-health-service.md` (the
on-machine assertions) and `…-ci-failure-alerting.md` (the CI half) — this is the
third leg: the machine telling someone it is still taking updates.

## Why this one matters more than it sounds

CLAUDE.md's driving risk is a **silent** stop. There are three places the update
chain can break, and today none of them is observed:

| where it breaks | who notices today |
|---|---|
| the pipeline stops building | nobody (`…-ci-failure-alerting.md`) |
| the machine stops fetching (mirror down, signature rejected, timer disabled by preset policy) | nobody |
| the machine fetches but never reboots into it | nobody |

The third is not hypothetical: our desktops **stage only** and apply at the next
natural boot, by design. A staff laptop that is suspended for six weeks is
carrying a staged update it has never applied, and looks identical from the
outside to one that is fully up to date.

The preset finding (`…-unit-enablement-preset.md`) is a live example of the
second row: if it does bite on installed machines, every one of them has been
silently not-updating since install, and the only reason we suspect it is that
someone read another repo's ADR.

## What infra built, and how much of it transfers

- `update-staleness` — a timer that checks how long since the machine last
  successfully pulled an image, and reports when that exceeds a threshold.
- `heartbeat.timer` — a 5-minute ping to healthchecks.io, **over a path that does
  not touch the tailnet**, so "the fleet is dead" and "the VPN is down" produce
  different symptoms.
- The important design decision (ADR 0025): the receiver is **off-site SaaS**, not
  the fleet's own server, because a server outage otherwise looks exactly like a
  dead fleet. They deleted a spool-and-forward design to get there.

Both scripts are short (~135 and ~74 lines) and depend on nothing infra-specific
beyond `bootc` and curl.

## What is different here, and must be decided before porting

- **Lab machines are off most of the time** and are on a school LAN behind
  whatever the site's DNS/firewall does. A 5-minute heartbeat is wrong for them;
  "did this machine check in at all this week" is the real question.
- **Nineteen machines is a lot of healthchecks.io checks.** Consider one check per
  machine (accurate, noisy, needs provisioning per machine) versus one check the
  *server* pings on behalf of the site after collecting from the LAN (cheap, but
  reintroduces the single point of failure ADR 0025 rejected).
- The school box in `../infra` (`boxes/svk`) already runs a receiver of exactly
  this shape for the Windows fleet (`winfleet-hub`: machines POST inventory, the
  hub writes files a CLI reads). Reusing that pattern for svk-os desktops is
  likely cheaper than inventing a second one, and it is already deployed at the
  right site — see `…-retire-svk-server-into-infra.md`.

## Recommendation

Do the **staleness** half first and keep it local: a timer that writes a plain
verdict a person can read (`ujust update-status` already exists as the manual
version), plus a on-screen or logged warning past a threshold. That is useful
with no infrastructure at all. Add the off-site ping only once the receiver
question above is settled, because the receiver choice is the part that is
expensive to change later.

## Outcomes

- [ ] `svk-update-staleness` timer: how long since the last successful fetch, and
      how long since the last *applied* deployment — the two differ here by design
- [ ] A threshold, and what happens when it is crossed
- [ ] Decide the receiver: per-machine SaaS check, or via the school box
- [ ] Whatever is chosen, prove it reports **red** once, on purpose
