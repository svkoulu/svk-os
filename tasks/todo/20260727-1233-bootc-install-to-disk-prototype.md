# Prototype `bootc install to-disk` as a replacement for the kickstart install path

Status: **open, unscheduled research.** Carved out of
`../done/20260726-2014-fde-tpm-and-install-path.md` §4 on 2026-07-27, when the rest
of that task (the TPM capability probe, the PCR-7 rationale, the QR recovery key)
landed without it. Never attempted.

This is a **"spend an afternoon finding out" item, not a planned migration.** Do not
put it on the critical path: the current kickstart works, is static text that does
not rot, and its failure mode is a room of unbootable laptops.

## The question

Today the install path spreads partitioning, LUKS, TPM enrollment and the update
origin across five places:

- the kickstart `%pre` that mints a per-install passphrase (`iso/installer/build.sh`)
- `svk-luks-bootstrap.ks`
- `svk-luks-tpm.ks`
- `files/os/usr/libexec/svk/luks-tpm-enroll`
- `bootc switch --mutate-in-place` in `svk-configure-upgrade.ks`

`bootc install to-disk` may collapse most of that into one command — it handles
partitioning, the bootloader, the deployment, and setting the origin, and
`--block-setup tpm2-luks` does LUKS + TPM2 natively.

## Verify before betting on it

1. Is `--block-setup tpm2-luks` still gated as experimental in the bootc shipped by
   our pinned Silverblue 44 digest? (`Containerfile.os`, `FROM …@sha256:b21b78d6…`)
2. **Which PCRs does it bind?** If it hardcodes something stricter than PCR 7, §1 of
   the parent task applies and this may be **disqualifying** — svk's PCR-7-only
   policy is deliberate, and a stricter default strands machines on firmware or
   kernel updates. This is the question most likely to kill the idea, so ask it
   early.
3. Does it do any TPM **capability** probing, or does it also just try and fail?
   (Added 2026-07-27.) `files/os/usr/libexec/svk/tpm2-capable` exists because a TPM
   2.0 older than v1.38 has a `/dev/tpmrm0` and still cannot hold an enrollment;
   discovering that by failure is what made a bad machine undiagnosable in a
   classroom. If `to-disk` regresses that, the probe has to survive the migration.
4. It has **no recovery-key story** — svk's `systemd-cryptenroll --recovery-key`
   slot would have to be added afterwards regardless, so `luks-tpm-enroll` does not
   fully disappear. Same for the acknowledgement-gated wipe of the bootstrap slot.
5. No localization, keyboard, timezone or user handling; those become ~20 lines of
   shell (Finnish locale + one account).

## How to run it

`just run-iso` already provides UEFI + an emulated TPM 2.0 via the `qemux/qemu`
container (`BOOT_MODE=uefi`, `TPM=Y` — needs `/dev/kvm` + `podman`, but no host
qemu or swtpm). See `iso/README.md`. That is the right harness; a dev box without
`podman`/`bootc` cannot answer any of the questions above, which is why this was
never attempted on 2026-07-27.

## What a positive result would mean

Not an automatic migration. Even a clean prototype has to beat "static kickstart
text that does not rot" on a fleet whose worst failure mode is a lab full of
machines that won't boot. Expect the outcome to be a written answer to the five
questions, plus a recommendation — not a branch.

Related:
- `../done/20260726-2014-fde-tpm-and-install-path.md` — parent; §1 (PCR policy) is a
  hard constraint on any replacement, §2 (the probe) is the behaviour to preserve.
- `20260726-2315-hardware-validation.md` §1 — the current install path is itself
  still unvalidated on hardware. Validate what exists before replacing it.
- `../done/20260726-1957-single-image-collapse.md` — why kickstart selection is two
  GRUB entries on one ISO (`OEMDRV` was considered and rejected); a `to-disk` path
  would have to keep the role split working.
