# Greenboot — automatic rollback when an update breaks the machine

Status: **not started.** Written 2026-08-19. Borrowed from `../infra`
(ADR 0010, 0011, 0017; `tasks/done/install-greenboot.md`,
`tasks/done/cap-greenboot-rollback-at-one.md`).

## The gap

Nineteen machines track `:stable` and stage updates automatically. If one update
is bad — a kernel that will not boot on that hardware model, a broken initramfs,
a unit that hangs the boot — every machine that takes it is bricked from the
point of view of the people who use it, and the repair is physical, per machine,
in a school.

`bootc` keeps the previous deployment and `bootc rollback` exists, but nothing
*calls* it. Rollback today requires a person at the machine choosing the previous
entry in the boot menu — which is the one thing lab users cannot be walked
through and staff should not have to be.

Greenboot is the missing piece: it runs health checks after boot, and if they
fail, it uses the GRUB boot counter to roll back to the previous deployment
automatically.

## What infra learned that we would otherwise repeat

Three things, each of which cost them a debugging session:

1. **Greenboot was not installed at all** despite being assumed present. It is a
   package (`greenboot`, `greenboot-default-health-checks`), and on their base it
   had to be added explicitly.
2. **The GRUB boot counter has to be laid down by the install path**
   (ADR 0011) — greenboot cannot roll anything back without it. They ship a
   `grub-greenboot-counter.service` to write it, because their installer never
   did. Ours (Anaconda) almost certainly does not either. Assert the counter
   counts down 3 → 2 → 1 → 0 across forced reboots; a flat counter means the
   machine reboots forever instead of rolling back, and a green run never shows
   it.
3. **Cap rollback at one per deployment** (ADR 0017), or a machine that is
   unhealthy for an unrelated reason (say, the network is down) rolls back
   repeatedly through its whole deployment history.

## What a health check should assert here

infra's only *required* check is "the tailnet is reachable", because for them
losing the access path is the unrecoverable state. Ours is different and needs
thought before writing any code — a lab machine has **no** remote access path by
design (no tailnet, LAN mDNS only), so "can I be reached" is not the criterion.

Candidates, roughly in order of how much they matter:

- **GDM reached a login prompt** (`graphical.target` active). If a student cannot
  log in, the machine is useless regardless of what else works.
- The LUKS volume unlocked without a prompt, where a TPM enrollment exists —
  though note a passphrase prompt blocks the boot before greenboot runs at all.
- `bootc status` reports a booted deployment matching the expected image.
- Deliberately **not**: anything requiring the network or the server. A school
  network outage must not roll back the fleet.

Note the asymmetry with infra worth writing down before implementing: a rollback
on a lab machine is recoverable in a way theirs is not (someone is physically
next to it every school day), while a *reboot loop* is much worse than a broken
desktop, because it takes the machine away from the class entirely. Bias the
checks conservative: few, cheap, and about the session rather than the services.

## Outcomes

- [ ] `greenboot` + `greenboot-default-health-checks` installed in
      `build/10-packages.sh`, enabled in both `build/20-services.sh` and
      `50-svk.preset`
- [ ] Boot counter present after an Anaconda install — verified, not assumed
- [ ] One required health check, written after deciding the criterion above
- [ ] Rollback capped at one per deployment
- [ ] Observed rolling back once, deliberately, in a VM — the mechanism is what
      is being tested, not the image
