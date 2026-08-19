# FDE: install-time TPM2 enrollment didn't happen on real hardware — encryption disabled

Status: **encryption commented out 2026-07-28** so hardware validation can proceed.
Supersedes nothing in `../done/20260726-2014-fde-tpm-and-install-path.md` (§1–3 of
that task are still right); this is the runtime validation of §2 coming back
negative, which that task explicitly deferred to
`20260726-2315-hardware-validation.md` §1.

## What happened

First real install: HP EliteBook 845 G7, AMD fTPM 2.0, Secure Boot enabled in
firmware, automated lab (`svk-lab.ks`) GRUB entry. Install completed, machine
rebooted, and the initramfs asked for a LUKS passphrase.

Evidence gathered from a live session:

- The disk *is* encrypted.
- `systemd-cryptenroll <dev>` lists **one slot, type password** — no `tpm2` slot,
  no `systemd-tpm2` token in `luksDump`.

So the chroot `%post` in `svk-luks-tpm.ks` (`iso/installer/build.sh`) never
enrolled anything. Which of its silent exits fired is unknown, and that is the
first thing to fix.

## Why this was worse than a prompt

The machine was **unrecoverable**, not merely inconvenient. The only passphrase
that could open the disk is the one minted in `%pre`, which lives in exactly two
places: the installer's RAM (gone at reboot) and `/etc/svk/luks-bootstrap` on the
encrypted disk (unreachable without it). The first-boot service that mints the
per-machine recovery key sits behind that same prompt, so it never ran.

The design assumed the fallback path was "type the bootstrap passphrase once".
Nothing in the install makes that passphrase available to the operator, so in
practice the fallback is a reinstall.

## Fix before re-enabling, in this order

1. **A failed enrollment must not brick the install.** Either print the bootstrap
   passphrase in a banner on the console before the reboot, or halt the install
   instead of rebooting. `--erroronfail` does not cover it today: the failures are
   `echo`s inside `if`s and a `|| echo` after `systemd-cryptenroll`.
2. **Diagnostics must survive a failed boot.** Everything currently logs to the
   Anaconda log on the encrypted disk. Write the probe output, `/etc/crypttab`,
   `/dev/tpmrm0` visibility and the post-enrollment `luksDump` check to the **ESP**
   (`/boot/efi/…`), which is unencrypted and readable from any live USB.
3. **Then find the actual cause.** Candidates, all indistinguishable from outside:
   the `tpm2-capable` probe (new in d222c78, never run on hardware) returning
   non-zero in the chroot; `/dev/tpmrm0` not visible in Anaconda's chroot;
   `/etc/crypttab` not yet written in the ostree deployment at `%post` time;
   `systemd-cryptenroll` itself failing.
4. **Verify before trusting.** After enrolling, assert the token exists
   (`cryptsetup luksDump | grep -q systemd-tpm2`) rather than assuming.

Iterate in a VM with an emulated TPM (`virt-install --tpm
backend.type=emulator,model=tpm-crb`) instead of on the laptop.

## Still open behind this

If enrollment turns out to land correctly but the disk still prompts, the cause is
one level down and is about *unlock*, not enrollment:

- **PCR 7 divergence** between the ISO's boot chain and the installed system's
  (`SbatLevelRT` is measured into PCR 7, and the ISO's shim and the image's shim
  are built at different times). Compare `tpm2_pcrread sha256:7` in the live
  session vs. the installed system. If they differ, install-time sealing can never
  work and enrollment has to move to first boot.
- **`rd.luks.options=tpm2-device=auto` never reaching systemd-cryptsetup.** dracut
  has two paths: with `rd.luks.uuid=` on the cmdline the option is honoured via
  systemd's generator; without it, `crypt-run-generator` writes the crypttab line
  itself (`luks-<uuid> <dev> - timeout=0,-`) and **discards `rd.luks.options`
  entirely**, so no TPM attempt is ever made. Verified by reading the generator out
  of the image's initramfs. Check `/proc/cmdline` on an installed machine.

Both of these argue for `bootc install to-disk --block-setup tpm2-luks`
(`20260727-1233-bootc-install-to-disk-prototype.md`), which does the LUKS + TPM
setup in the installed context by construction.

## What was changed to disable it

- `iso/installer/build.sh`, `common_ks()`: `autopart --type=btrfs --noswap` (plain);
  the `%include /tmp/svk-storage.ks`, `bootloader --append=…`, the `%pre`
  passphrase mint, and the two `%include`s of `svk-luks-bootstrap.ks` /
  `svk-luks-tpm.ks` are commented out with restore instructions.
- Both `%post` scripts are still *generated* (and are inert without a `%pre`-minted
  passphrase); `interactive-defaults.ks` still includes them.
- The image side is untouched: `svk-luks-tpm-enroll.service`, `luks-tpm-enroll` and
  `tpm2-capable` still ship and are no-ops via `ConditionPathExists`.
- `iso/README.md` carries a banner saying the section describes the state to
  restore, not the current one.

---

## Update 2026-08-19 — static review of the failure paths, and a fix proposal

No hardware involved; this is what reading the code says, to narrow what the next
install has to look at.

### The FDE-disabled state is consistent — one thing checked and cleared

`svk-luks-bootstrap.ks` and `svk-luks-tpm.ks` are still `%include`d, uncommented,
by `interactive-defaults.ks` (the live-session fallback path) while the two role
kickstarts have them commented out. That looked like a divergence and is not:
both scripts guard on the per-install passphrase file, which that path never
creates, so they are inert there. No action.

### The four places the chroot `%post` can exit without saying anything

In order of how much evidence would survive:

1. `[ -f /etc/svk/luks-bootstrap ]` false — the preceding `--nochroot` `%post`
   did not write it. Would mean the failure is *before* anything TPM-related.
2. `tpm2-capable` non-zero — this one *does* echo a reason, but only into the
   installer's log, on a machine that then rebooted into an unanswerable prompt.
3. `[ -n "$uuid" ] && [ -e "$dev" ]` false — `/etc/crypttab` not yet written in
   the chroot, or `/dev/disk/by-uuid/` not populated inside it. **This is the only
   branch that produces no message at all**, and it is also the one most likely to
   differ between a chroot and a booted system.
4. `systemd-cryptenroll` itself failing — echoes "first boot will retry", again
   only into the installer log.

So three of the four leave a line in the installer log and one leaves nothing —
and none of them reaches the operator, because the machine reboots into a prompt
that cannot be answered. **The diagnosis problem is not the enrollment, it is that
the evidence dies with the installer environment.**

### Proposed fix, in the order the task already has it

1. **Make the evidence survive.** Write a plain-text install log to the ESP
   (`/boot/efi/EFI/svk/install.log` — mounted in the chroot, readable from any
   machine, unencrypted by definition). Log every branch above by name, including
   the ones that currently exit silently, plus the probe's own message. **No
   secrets in it** — never the passphrase, never the recovery key. The ESP is
   readable by anyone holding the laptop, which is exactly why it is a good place
   for diagnostics and a terrible one for a key.
2. **A failed enrollment must not brick the install.** The current design mints a
   passphrase that exists only in installer RAM and on the encrypted disk, so a
   failed enrollment produces an unanswerable prompt. Do not solve this by writing
   the passphrase anywhere on disk — that defeats the encryption for a stolen
   laptop, which is the entire threat model for a school. Solve it by **not
   rebooting**: on enrollment failure, print the passphrase on the console with a
   loud banner and halt, so the operator captures it before the machine leaves the
   desk. An attended install is a precondition either way.
3. **Then** find out which branch fired, from the ESP log, on the next attempt.

### Test it at the desk first

`swtpm` under qemu reproduces all of this — an emulated TPM 2.0 with Secure Boot
is enough to exercise the probe, the enrollment and the auto-unlock, and it is
the cheapest possible place to iterate on step 1. That is the same harness
`…-tier2-boot-smoke-test.md` needs, which is an argument for building it before
re-enabling FDE rather than after.
