# Decision records and install runbooks

Status: **not started.** Written 2026-08-19. Borrowed from `../infra`
(`docs/adr/`, `docs/runbooks/`, and the "keep it short" rules in its CLAUDE.md).

## Where rationale lives today, and why that is a problem

`CLAUDE.md` (12 KB) and `README.md` (11 KB) carry almost all of the reasoning in
this repo, mixed in with the how-to. Both are read start-to-finish by anyone
arriving, both grow with every decision, and neither can record that a decision
was *reversed* — the FDE disablement of 2026-07-28 is a "BRING-UP:" comment in
`Containerfile.os`, a commented-out block in `iso/installer/build.sh` and a task
file, and nothing that a reader of CLAUDE.md would find.

infra's split works because it separates three things this repo currently mixes:

| kind | question it answers | where |
|---|---|---|
| ADR | why is it like this, what was rejected | `docs/adr/NNNN-*.md` |
| runbook | what do I type, with hardware in front of me | `docs/runbooks/*.md` |
| task | what are we doing right now, and did it land | `tasks/` (we have this) |

## Runbooks matter more here than they do in infra

infra's fleet is three boxes installed by the person who wrote the repo. Ours is
**nineteen machines installed by a person standing in a school**, twice over (lab
and staff), possibly not the author, possibly a year from now. Today the install
procedure exists as: a TODO.md checklist written as one-time setup, an
`iso/README.md` aimed at whoever builds the ISO, and a hardware-validation task
file. None of them is "here is what you do at the machine".

The runbook rules worth copying verbatim:

- **one path, the default one**, short enough to follow standing up
- variants get their own file named after the case (`install-no-tpm.md`)
- procedure only — rationale goes in the ADR, or the runbook grows until nobody
  reads it
- the checklists (firmware settings that cannot be changed remotely, what to
  verify before walking away) live in **one** file, not summarised per-role

## Suggested first set

ADRs, each of which is currently reasoning buried in a comment or a task file:

1. One image, no build-time flavors — the account-scoped lockdown
2. The fleet tracks a rolling `:stable` tag, cut from git tags
3. Keyed cosign signing, and why keyless would break the fleet
4. Flatpaks are an ISO-install artifact, not an image or first-boot artifact
5. Enablement is stated twice (`…-unit-enablement-preset.md`)
6. FDE: PCR 7 only, per-install passphrase, recovery key shown once — **and its
   current disabled state, with the condition for re-enabling**

Runbooks:

1. `install-lab.md` / `install-staff.md` — at the machine, from USB to done
2. `install-checklists.md` — firmware, pre-walk-away verification, both roles
3. `build-iso.md` — extracted from `iso/README.md`, which is currently design +
   procedure + environment gotchas in one file
4. `recovery.md` — LUKS recovery key, rollback to the previous deployment,
   re-pointing a machine's update origin

## Outcomes

- [ ] `docs/adr/` and `docs/runbooks/` exist with the numbering/format convention
- [ ] The six ADRs above written, and the corresponding prose **removed** from
      CLAUDE.md/README.md rather than duplicated
- [ ] The install runbooks written and used, once, by someone following them
      literally — that is the only test that matters for a runbook
