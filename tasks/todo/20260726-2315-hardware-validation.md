# Hardware / VM validation checklist — nothing here has ever run on real metal

Status: **not started.** Consolidated 2026-07-26 from the rebuild plan step 7, the
fleet-update-cadence spec (shipped in 0cdaf5a by inspection only), and
`iso/README.md:219`. Single largest open risk in the project: a CI pipeline that
has never been proven to produce a machine that boots, unlocks, logs in and updates
itself. The single-image collapse landed 2026-07-27, so "student"/"staff" are
accounts on one image and everything it added is also unproven.

`just run-iso <flavor>` gives emulated TPM 2.0 + UEFI — do the VM pass first.

## Blockers (gate everything, or fail OPEN)

- [ ] End-to-end ISO build + install — 685dc5b's `anaconda.target` GRUB entry has never been re-tested since the 2026-07-21 `liveinst` failure.
- [ ] `DCONF_PROFILE=kiosk` takes effect before the session's first dconf read — otherwise opilas silently gets an unlocked desktop.
- [ ] `/etc/dconf/db/kiosk` is compiled and non-empty — a silently empty db means no lockdown and nothing reports it.
- [ ] LUKS + TPM2 auto-unlock works on reboot after install, PCR 7 only (do not "harden").
- [ ] Recovery key is displayed on screen and actually unlocks.
- [ ] `/usr/libexec/svk/tpm2-capable` agrees with real hardware both ways (unit-tested against stubs only).
- [ ] No-TPM machine: legible banner, no retry loop, recovery key works, passphrase slot kept.
- [ ] `bootc-fetch-apply-updates.service` has **no `--apply`** on desktops, still `--apply` on server — `--apply` reboots mid-lesson.
- [ ] Decide how an operator gets a local GUI session: sysusers creates `admin` password-LOCKED, so "Not listed?" has nothing to authenticate against.

## High (fleet-wide correctness)

- [ ] Kiosk autologin works — `opilas` now created locked by the lab kickstart, autologin written by its role `%post`; neither has run.
- [ ] Staff laptop stays inert: both kiosk units log as *skipped* (ExecCondition), no dconf lockdown, Bluetooth not blocked at boot.
- [ ] Id map is exactly `admin` 1000 / `staff` 1001 / `opilas` 1002 on both roles.
- [ ] `admin` absent from the greeter (`SystemAccount=true` via tmpfiles), and still absent after a reboot and an image update.
- [ ] Prepended `XDG_DATA_DIRS` hides restricted launchers **without** losing flatpak app-grid entries.
- [ ] App matrix: `staff` gets gnome-software only, `opilas` none, `admin` all — and gnome-software's `--gapplication-service` autostart fails quietly for `opilas`.
- [ ] Staff flatpak install from gnome-software: no admin prompt, lands in **system** scope, `opilas` can launch it.
- [ ] Student home reset fires and the baked flatpaks survive it.
- [ ] Firefox + the baked flatpak set launch fully offline on first boot.
- [ ] Stage-only `bootc upgrade --quiet`: old deployment keeps running, new one boots later.
- [ ] `svk-flatpak-update.service` touches only `--system` and survives one simulated network failure.

## Medium (tooling and observability)

- [ ] mDNS resolution, admin SSH (key-only, `AllowGroups wheel`), hostname claim against the dispenser.
- [ ] `systemctl list-timers`: both timers enabled with the expected `OnCalendar` / `RandomizedDelaySec`.
- [ ] `ujust update-now`: both units start, one correct line in `/var/log/svk/update.log`, **no reboot**.
- [ ] `ujust update-apply-now`: applies, reboots, and the log line is intact on the other side.
- [ ] `ujust update-status` matches the log tail and `list-timers`.
- [ ] Mid-update network failure logs a clear failed run, not silence.
- [ ] Both services' journals survive a reboot (persistent journald drop-in).
- [ ] `check-drift` is clean on an unmodified image, and catches a hand-edited `/etc` file.
- [ ] `channel-status` / `toggle-channel` report and switch correctly, machine boots the other channel.
- [ ] `luks-status` reports the TPM2 slot, and fails gracefully on an unencrypted dev build.
- [ ] `powerwash` refuses on anything but an exact hostname match; `bootc install reset --experimental` still correct for the pinned bootc.
- [ ] Run **every** ujust recipe as `admin` over real SSH — the `pkexec`→`sudo` swap is what's being tested.

## Low

- [ ] `device-info` / `bios-info` are useful and make no network call.
- [ ] `clean-flatpaks` behaves.
- [ ] `just` really is in Fedora's repos (no COPR) — CI has probably settled this.
- [ ] `/var/log/svk` at `0750 root:root` (so readers need `sudo`) was an implementation default, not a pinned decision.

## Note

The old "should staff get gnome-software" question is **dead** — the collapse answers
it yes, gated by group. Do not re-open it from the archived spec.

---

## Update 2026-08-19 — three blockers moved, one new one appeared

Run at the desk against a locally-built image, not on metal. What changed:

**Now asserted at build time** (`ci/verify-image.sh`,
`…-tier1-image-verification.md`) and no longer needing hardware:

- `/etc/dconf/db/kiosk` is compiled and non-empty — and, more than the original
  item asked, that it actually contains the lock keys from `00-svk-locks`. A db
  that compiled from an unreadable source directory is valid and empty, so file
  existence proved nothing.
- `bootc-fetch-apply-updates.service` has **no `--apply`** on desktops.
- The fleet-wide dconf `user` profile does not select the kiosk db (the
  machine-wide-lockdown mistake CLAUDE.md warns about).

**New blocker, ranked above most of this list:** first-boot preset policy
disables 10 of the 11 units we enable — reproduced against the image on
2026-08-19 (`…-unit-enablement-preset.md`). A preset file now ships and the
simulation passes with it in place. What is **not** proven is whether a real
Anaconda install triggers the first-boot path at all; that cannot be tested in a
container (systemd skips first-boot setup entirely when it detects a container,
so the obvious experiment silently answers "no"). It needs a VM or a machine.

Add to this checklist, at the top, for the next install of any kind:

- [ ] After first boot, all eleven units report `enabled`:
      `systemctl is-enabled sshd avahi-daemon tailscaled svk-claim-hostname
      bootc-fetch-apply-updates.timer svk-flatpak-update.timer
      svk-power-profile reset-opilas-home svk-bluetooth-default-off
      svk-luks-tpm-enroll svk-tailscale-enroll`
- [ ] Run the same command on the EliteBook installed 2026-07-28. It predates the
      preset file, so if the trap is real that machine has had no SSH, no
      Tailscale and no automatic updates since the day it was installed — which
      would also mean the fleet has never once been observed updating itself.

**Also found, and fixed, without hardware:** power switching has never worked at
all — Fedora 44 ships `tuned-ppd`, not `power-profiles-daemon`, and the script
called a binary that does not exist while suppressing the error
(`…-power-profile-tuned-ppd.md`). The checklist item for it stands; it would have
been read as a hardware quirk.


---

## Update 2026-08-19 (second) — the first VM install actually ran

Full account in `…-first-end-to-end-vm-install.md`. Against this checklist:

**Closed by observation:**

- [x] End-to-end ISO build + install — the automated LAB GRUB entry installs with
      zero interaction and reboots. `anaconda.target` works; the 2026-07-21
      `liveinst` failure does not recur.
- [x] The eleven units are enabled after a real first boot.
- [x] The account model: `opilas` 1002 + `admin` 1000 and no `staff` on a lab
      install.
- [x] The update origin is the signed ref.
- [x] Power switching works (over tuned-ppd's D-Bus API, after the fix).

**Newly broken, found only by installing:**

- [ ] **The machine boots to a text console** — Anaconda sets the default target
      to multi-user, GDM never starts. Fixed in the kickstart, **not yet
      re-tested**. Until it is, every item on this list that needs a graphical
      session is untestable, which is most of them.
- [ ] **`svk-claim-hostname` never ran** — `ConditionFirstBoot` is never true on
      this install path. Fixed in the unit, not yet re-tested.
- [ ] `systemd-remount-fs.service` fails on every boot (fstab `ro` on the btrfs
      root). Cosmetic today; it is a permanently failed unit on a fresh install.

**Still untested, and now known to be untested:** everything downstream of a
graphical session (`DCONF_PROFILE` timing, the lockdown, autologin, the per-account
app restrictions), the flatpak bake (that ISO was built with no flatpaks), and all
of FDE/TPM (still disabled).
