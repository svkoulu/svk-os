# FDE: TPM enrollment hardening, and the `bootc install to-disk` question

Status: **implemented 2026-07-27** (§1–3). Noted 2026-07-26. **§4 was carved out
into `../todo/20260727-1233-bootc-install-to-disk-prototype.md`** and is the only
part of this task not done — see the note under §4 below.

The original plan was to prototype §4 first, because a viable `bootc install
to-disk --block-setup tpm2-luks` would replace most of the code §2–3 improve. That
ordering was **abandoned deliberately**: §2 is ~40 lines that fix a real
boot-forever failure mode on mixed hardware, §4 is an open-ended VM experiment that
this task itself says must not go on the critical path. Waiting on the experiment to
land the cheap fix had the ordering backwards. Splitting it out is the same call made
explicit — nothing in §1–3 depends on it, and if §4 ever wins it deletes that code
rather than conflicting with it.

Read the **Implementation notes** at the bottom; the spec below is kept as written
as the record of the decisions. Note §3 turned out to be **already implemented**
before this task was picked up.

Runtime validation of §2 is **not** part of this task being done — it lives in
`../todo/20260726-2315-hardware-validation.md` §1, which was updated with the
probe-specific checks.

---

## 1. Do NOT "fix" the PCR list

`files/os/usr/libexec/svk/luks-tpm-enroll` binds the TPM2 enrollment to
**PCR 7 only** (`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7`).

This is deliberate and correct — recording it here so nobody "hardens" it later.

A PCR (Platform Configuration Register) is a TPM hash accumulator that each boot
stage extends with a measurement of the next. Sealing the LUKS key to a set of
PCRs means the TPM only releases it if the machine booted the same way. Bind more
PCRs and you get a stricter policy — and more machines stranded at a recovery
prompt:

- PCR 0 — firmware code: changes on **every BIOS update**
- PCR 1 — firmware config: changes when **any BIOS setting is toggled** or
  hardware is added
- PCR 4 — bootloader, PCR 5 — partition table, PCR 9 — initrd
- PCR 7 — Secure Boot state and keys

Aeon binds `4,5,7,9` and documents excluding 0–3. svk's PCR-7-only policy is
**more** conservative than Aeon's: firmware updates and kernel/initrd updates
don't strand a machine, only a Secure Boot key change does. On mixed school
hardware that is the right trade — Aeon has six open issues in exactly this
territory (AeonDesktop/Project #15, #24, #27, #31, #35, #36).

An earlier suggestion in this project to port Aeon's PCR list was **wrong and is
retracted**.

## 2. Worth porting from tik: the TPM capability probe

`../aeon-os/tik-upstream/usr/lib/tik/modules/pre/15-encrypt` probes the TPM
*before* committing to an encryption mode:

- check for `/dev/tpmrm0`
- then `tpm2_getcap commands | grep 'commandIndex: 0x192'` — the
  `PolicyAuthorizeNV` command, absent on TPMs older than v1.38
- no TPM, or TPM lacking that command → **fallback mode**: warn the user, check
  Secure Boot state, and prompt for a passphrase instead

svk currently discovers an inadequate TPM only by having the enrollment fail
(`luks-tpm-enroll:69-71` tries and falls through). The machine then silently
prompts for the bootstrap passphrase on every boot, and the technician has to
work out why. Probing up front and saying so is strictly better on mixed
hardware.

## 3. Worth porting: QR-coded recovery key

`luks-tpm-enroll:63` already mints a recovery key via
`systemd-cryptenroll --recovery-key`. Aeon displays the equivalent as a QR code
(`qrencode -t UTF8i`). Trivially better than "photograph the screen" or reading
a 32-char string off tty3 during provisioning.

> **Already done when this task was picked up (2026-07-27).** `luks-tpm-enroll`
> renders the key with `qrencode -t ANSIUTF8` (`ANSIUTF8`, not tik's `UTF8i` —
> same glyphs, with ANSI colour so it survives a dark-background VT), and
> `qrencode` is in `build/10-packages.sh`. No change needed.

## 4. Prototype `bootc install to-disk` (do this first) — MOVED OUT

**Not done, and not attempted.** The full spec now lives in
`../todo/20260727-1233-bootc-install-to-disk-prototype.md`; it is a research
question with its own lifetime, and leaving it inside a task marked done would have
hidden it. Summary of what moved: `bootc install to-disk --block-setup tpm2-luks`
might collapse the five places that currently spread partitioning / LUKS / TPM
enrollment / update origin into one command, and there are five things to verify
before betting on it (one of them added by the §2 work — whether it probes TPM
capability at all, or also just tries and fails).

The "do this first" in the heading above is the ordering that was **abandoned**; see
the Status note at the top.

Note the `OEMDRV` option for kickstart selection was considered and **rejected** —
GRUB entries on one ISO were chosen instead (see
`20260726-1957-single-image-collapse.md`).

---

## Implementation notes (2026-07-27)

**§1 — PCR list.** No code change (that was the point). The rationale is now
recorded *at both enrollment sites* so it is visible to whoever is tempted:
`luks-tpm-enroll` step 2, and the `svk-luks-tpm.ks` heredoc in
`iso/installer/build.sh`. Both name this file.

**§2 — capability probe.** Added `files/os/usr/libexec/svk/tpm2-capable`: checks
`/dev/tpmrm0` is a char device, then `tpm2_getcap commands` for
`commandIndex: 0x192` (`PolicyAuthorizeNV`). Prints a one-line reason and exits
0 = usable, 1 = no TPM 2.0, 2 = chip older than v1.38, 3 = chip did not answer.

Four things came out differently from a literal port of tik:

1. **One probe, both ends.** It ships in the *image*, not the ISO, and the kickstart
   `%post` calls it from the chroot — so the install-time decision and the
   first-boot decision cannot drift. `tpm2-tools` was already installed in both.
2. **`/dev/tpm0` alone now counts as "no TPM".** The old kickstart accepted
   `tpmrm0 || tpm0`; systemd's `--tpm2-device=auto` needs the kernel resource
   manager, so a `tpm0`-only machine is a TPM 1.2 that could only ever fail. tik
   checks `tpmrm0` only, and is right.
3. **No "prompt for a passphrase instead" fallback.** tik is interactive; svk
   installs under `inst.cmdline` with a per-install passphrase already minted, so
   there is nobody to prompt. svk's fallback is the recovery key, which §3 already
   prints — the probe's job here is to *name the reason* and to stop retrying.
4. **Secure Boot state is reported, not enforced.** tik uses `mokutil --sb-state`;
   svk doesn't ship `mokutil`, so `luks-tpm-enroll` reads the EFI variable directly
   (`SecureBoot-8be4df61-…`, byte 5) rather than adding a package for one string.
   Shown only in the no-usable-TPM banner, as tik does.

**The convergence fix this enabled** (not in the original spec, but the actual
payoff). Knowing *why* enrollment won't work splits one branch into two:

| outcome | before | now |
|---|---|---|
| TPM enrolled | wipe bootstrap slot, disable service | unchanged |
| capable TPM, enrollment failed | keep slot, retry next boot | unchanged |
| **no usable TPM** | keep slot, **retry forever** — machine prompts for an ISO-era passphrase nobody recorded | stop retrying; recovery key becomes the every-boot secret, said so on screen |

In that third case the bootstrap slot is wiped **only if a human pressed ENTER** on
the recovery-key banner (`read` timing out is now captured as `acked=0`). Wiping it
unattended would leave a disk whose sole secret nobody wrote down — a worse failure
than keeping a per-install passphrase that never shipped in the ISO. When it is
kept, the exact `--wipe-slot=password` command to finish by hand goes to the
journal. This relies on `systemd-cryptenroll --wipe-slot=password` sparing the
recovery key, which systemd tracks as its own `recovery` slot type; there is a
comment at the wipe saying so, because the third branch is unsafe without it.

**Verification.** `bash -n` + `shellcheck -S warning` clean on both scripts and on
the extracted `%post` body. The three-way logic was exercised against stubbed
`systemd-cryptenroll`/`tpm2_getcap`/`systemctl` in a sandboxed root — five paths
(capable, capable-but-failing, `tpm0`-only, old chip, and acknowledged vs.
unacknowledged no-TPM) all produce the intended slot/stamp/crypttab end state.
**No image build, no VM, no hardware**: `ksvalidator` is not installed here either,
so the kickstart change is syntax-checked but not schema-validated. Hardware items
went to `../todo/20260726-2315-hardware-validation.md` §1, including the one that
matters —
the probe's verdict must match what enrollment actually does on the school's
machines, in *both* directions.
