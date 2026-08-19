# Tier 2 — boot the built image in a VM and assert on the result

Status: **not started.** Written 2026-08-19 alongside the tier-1 port. This is the
half of `../infra`'s verification model that svk has no equivalent of at all.

## The gap

Nothing has ever watched an svk-os machine boot before the fleet took the image.
`just run-iso` exists, but it is an **eyeball** test: a person boots the ISO, looks
at a web console, and forms an opinion. Nothing records what was true, nothing
fails, and nothing can run it while you are asleep.

Meanwhile `:stable` is published from a git tag and the fleet tracks `:stable`.
The gate between "a commit was tagged" and "nineteen machines take it" is
currently a build that compiles.

infra treats this as the load-bearing distinction (ADR 0020): tier 1 is static
and runs on every push; tier 2 is a **real boot** with assertions, and `:stable`
does not move unless it passes. They proved both halves of that gate on
2026-08-11 — including deliberately pushing a broken image through and watching
`promote` refuse to run.

## What tier 2 should assert for svk

The install path is different (Anaconda kickstart, not `bootc switch` onto stock
FCOS), so the harness differs from infra's, but the assertions are the same shape:

1. **The eleven units are enabled and active after first boot** — the single most
   valuable assertion available, because it is the one that catches the preset
   trap (`…-unit-enablement-preset.md`) and it is invisible from outside.
2. **`opilas` exists on a lab install, does not on a staff install**, and the
   kiosk units report *skipped*, not failed, where it is absent. This is the
   entire basis of the single-image collapse and has never been observed.
3. **`DCONF_PROFILE=kiosk` is in effect for the opilas session** and a lockdown
   key actually reads as locked — not merely that the db exists (tier 1 covers
   that).
4. **LUKS + TPM2**: the disk is encrypted, a `tpm2` token is present in
   `luksDump`, and the second boot reaches the login prompt with no passphrase
   prompt. `swtpm` under qemu is enough to test all three, and it is what would
   have caught the 2026-07-28 hardware failure at the desk
   (`…-fde-install-enrollment-failed-on-hardware.md`).
5. **Both baked flatpaks and the app grid survive** — `flatpak list --system`
   shows the full set with no network, and the prepended `XDG_DATA_DIRS` did not
   cost the app-grid entries.
6. **The update origin is the signed ref** — `bootc status` reports
   `ghcr.io/svkoulu/svk-os:stable` and signature enforcement is on.

## Shape

Follow infra's split rather than one big script:

- `ci/smoke-test.sh` drives the VM (boot the ISO, run the install unattended,
  reboot, wait for SSH as `admin` over the key we ship)
- `ci/smoke-assert.sh` runs the assertions over that SSH connection and prints
  ok/FAIL per line, so a failure names itself

infra's versions are directly readable as a model; the assertions are ours.

## The hard parts, honestly

- **The ISO build needs root podman** (Titanoboa's privileged squashfs/loop
  work), and GitHub's hosted runners can do that, but they have **no KVM** — so
  the boot half cannot run on a hosted runner at all. infra solved the same
  problem with a self-hosted runner on a fleet box (ADR 0020). The equivalent
  here is a runner on the school box, or accepting that tier 2 is a
  **workstation-only** gate run before cutting a tag.
- **Recommendation**: build it workstation-first (`just smoke`), make it
  assert-and-exit-nonzero from day one, and treat "runs in CI" as a later,
  separate question. A tier 2 that a person runs before tagging is worth far more
  than a tier 2 that is still being designed.
- The `qemux/qemu` container `just run-iso` already uses gives KVM + UEFI +
  emulated TPM 2.0 with no host qemu/swtpm needed, which is a reasonable base to
  automate against — but it is driven through a web console. Driving qemu
  directly (with `swtpm`, `-serial`, and a kickstart-triggered
  `poweroff`/serial marker) is likely to be less fighting than automating VNC.

## Outcomes

- [ ] `ci/smoke-test.sh` boots the ISO and completes an unattended lab install
- [ ] `ci/smoke-assert.sh` asserts the six groups above, one line each
- [ ] `just smoke` runs both and exits nonzero on any failure
- [ ] A deliberately broken image is pushed through it once and observed red —
      an unexercised gate is not a gate (infra proved theirs this way)
- [ ] Decide where it runs: workstation-before-tag, or a self-hosted runner
