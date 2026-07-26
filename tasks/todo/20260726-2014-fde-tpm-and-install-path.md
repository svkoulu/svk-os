# FDE: TPM enrollment hardening, and the `bootc install to-disk` question

Status: **deferred, not scheduled.** Noted 2026-07-26. These two are filed
together because they are coupled: if `bootc install to-disk --block-setup
tpm2-luks` turns out to be viable, it *replaces* most of the code the Aeon ports
below would improve, so prototype that first before investing in the ports.

---

## 1. Do NOT "fix" the PCR list

`files/base/usr/libexec/svk/luks-tpm-enroll:71` binds the TPM2 enrollment to
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

## 4. Prototype `bootc install to-disk` (do this first)

Today the install path spreads partitioning, LUKS, TPM enrollment and the update
origin across five places:

- the kickstart `%pre` that mints a per-install passphrase
  (`iso/installer/build.sh`)
- `svk-luks-bootstrap.ks`
- `svk-luks-tpm.ks`
- `files/base/usr/libexec/svk/luks-tpm-enroll`
- `bootc switch --mutate-in-place` in `svk-configure-upgrade.ks`

`bootc install to-disk` may collapse most of that into one command — it handles
partitioning, the bootloader, the deployment, and setting the origin, and
`--block-setup tpm2-luks` does LUKS + TPM2 natively.

**Verify before betting on it:**

- Is `--block-setup tpm2-luks` still gated as experimental in the bootc shipped
  by our pinned Silverblue 44 digest?
- It has **no recovery-key story** — svk's `--recovery-key` slot would have to be
  added afterwards regardless.
- No localization, keyboard, timezone or user handling; those become ~20 lines of
  shell (Finnish locale + one account).
- Which PCRs does it bind? If it hardcodes something stricter than PCR 7, section
  1 above applies and it may be disqualifying.

Prototype in a VM. Do **not** put this on the critical path — the current
kickstart works, is static text that does not rot, and its failure mode is a room
of unbootable laptops. This is a "spend an afternoon finding out" item, not a
planned migration.

Note the `OEMDRV` option for kickstart selection was considered and **rejected** —
GRUB entries on one ISO were chosen instead (see
`20260726-1957-single-image-collapse.md`).
