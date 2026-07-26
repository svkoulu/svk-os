# Hardware / VM validation backlog — nothing here has ever run on real metal

Status: **not started.** Consolidated 2026-07-26 from three places that each left
a validation section unrun:

- `20260717-1845-modular-base-rebuild-implementation-plan.md` step 7 (now in
  `tasks/done/`) — install one machine of each role and exercise it.
- `20260719-2126-fleet-update-cadence.md` (now in `tasks/done/`) — the update
  cadence, ujust tooling and logging shipped in 0cdaf5a **by inspection only**;
  no podman was available in the session that wrote them.
- `iso/README.md:219` — the unchecked boxes in "TODOs before ISOs ship".

This is the single largest open risk in the project: a working CI pipeline that
has never been proven to produce a machine that boots, unlocks, logs in and
updates itself.

## Sequencing — read before starting

**The collapse has landed** (`tasks/done/20260726-1957-single-image-collapse.md`,
2026-07-27), which was the recommended prerequisite: validating the old
four-image layout would have meant validating something already scheduled for
deletion. So "student" and "staff" below are **accounts on one image**, not two
images, and roughly half the matrix is now one pass instead of two.

What the collapse ADDED to this backlog, all of it unproven on metal:

- `DCONF_PROFILE=kiosk` via `environment.d` must take effect **before** the
  session's dconf is first read. If it doesn't, opilas silently gets an unlocked
  desktop — a fail-OPEN mode, so check it first.
- The prepended `XDG_DATA_DIRS` must shadow the restricted launchers **without**
  costing the flatpak app-grid entries (flatpak's own user-environment generator
  runs after systemd's `30-systemd-environment-d-generator` and appends its export
  dirs — expected to compose, never verified).
- The `svk-staff` group, the mode-0750 app matrix, and the flatpak polkit grant.
- `opilas` created by the **kickstart** rather than `sysusers.d`, and GDM autologin
  written by the kickstart's role `%post`.
- Two ExecCondition-gated kiosk units that must be *skipped*, not *failed*, on a
  staff laptop.

Still worth doing early and independently: the end-to-end ISO build and the
LUKS/TPM path, because a broken installer invalidates everything else.

## 1. Installer — does an ISO produce a machine at all

- **End-to-end ISO build + install.** The 2026-07-21 on-hardware attempt failed
  on `liveinst`'s "kickstart is not supported on live iso installs"; 685dc5b
  added the automated `anaconda.target` GRUB entry to fix it. **That fix has
  never been re-tested.** This is the gate on everything below.
- **LUKS + TPM2 auto-unlock.** Confirm a TPM machine auto-unlocks on the reboot
  after install, bound to PCR 7 only (`files/base/usr/libexec/svk/luks-tpm-enroll:71`
  — deliberate, see `20260726-2014-fde-tpm-and-install-path.md`, do not "harden").
- **Recovery key** is displayed on screen and actually works to unlock.
- **No-TPM machine**: confirm the documented interim (operator reads
  `/tmp/svk-luks-bootstrap` from the installer console before reboot) is workable,
  or accept it as a known gap until the provisioning USB lands.
- `just run-iso <flavor>` gives an emulated TPM 2.0 + UEFI, so the unlock path is
  testable in a VM before touching a laptop. Use it first.

## 2. Post-install identity and lockdown

- Kiosk autologin works after install. NOTE: `opilas` is now created **locked, by
  the lab kickstart** (not `sysusers.d`), and GDM autologin is written by that
  kickstart's role `%post` — both moved in the collapse and neither has run.
- **Account scoping holds.** On a staff laptop there is no `opilas`: the two kiosk
  units must log as *skipped* (ExecCondition), the dconf lockdown must be absent,
  and Bluetooth must not be blocked at boot. On a lab machine the lockdown must be
  present. A machine with no `opilas` must never end up with an unlocked kiosk
  profile — confirm inert, not absent.
- **Per-account app matrix**: `staff` launches gnome-software but not
  Terminal/Disks/System Monitor (and sees no icons for them); `opilas` launches
  none of them; `admin` launches all. Confirm gnome-software's background
  `--gapplication-service` autostart fails **quietly** for `opilas` (it is not
  covered by the XDG_DATA_DIRS shadowing — that's XDG_CONFIG_DIRS territory).
- **Staff flatpak install**: `staff` installs from gnome-software with no admin
  password prompt, it lands in **system** scope, and `opilas` can launch it.
- Student home reset fires and the **baked flatpaks survive it** (they are in
  `/var/lib/flatpak`, system scope — this is the whole reason for that choice).
- Firefox and the baked flatpak set are present and launchable **fully offline**
  on first boot.
- dconf lockdown db compiled and non-empty — now `/etc/dconf/db/kiosk`, not
  `local` (the fleet-wide defaults stayed in `local`; the locks moved to their own
  db so staff don't inherit them). A silently empty `kiosk` db means the kiosk is
  not locked down at all and nothing currently reports that.
- mDNS resolution, admin SSH (key-only, `AllowGroups wheel`), hostname claim
  against the server's dispenser.
- `admin` is hidden from the greeter (uid **480** < `UID_MIN`) but reachable via
  "Not listed?". **Open question surfaced during the collapse:** sysusers creates
  admin with a LOCKED password, so "Not listed?" has nothing to authenticate
  against — decide how an operator actually gets a local GUI session before
  relying on the admin-only app matrix.

## 3. Update cadence, tooling and logging (0cdaf5a — inspection-only)

- `systemctl list-timers`: `bootc-fetch-apply-updates.timer` and
  `svk-flatpak-update.timer` enabled with the expected per-flavor `OnCalendar` /
  `RandomizedDelaySec`.
- `systemctl cat bootc-fetch-apply-updates.service`: **no `--apply` on desktops**,
  still `--apply` on server. This is the check that matters most — `--apply`
  reboots the moment an update stages, which on a classroom machine means a
  reboot mid-lesson.
- Force a stage-only update (`bootc upgrade --quiet`): machine keeps running the
  old deployment until a later reboot, then boots the new one.
- `svk-flatpak-update.service` touches only `--system`, never a `--user` install,
  and survives one simulated network failure via its `Restart=` policy.
- `ujust update-now`: both units start, one correct line lands in
  `/var/log/svk/update.log` (before/after version, exit 0, plausible duration),
  **no reboot**.
- `ujust update-apply-now`: applies and reboots; the log line for that run is
  present and correct **on the other side of the reboot** (proves `/var/log/svk`
  persistence rather than journald).
- `ujust update-status` matches the log tail and `systemctl list-timers`.
- Network failure mid-update logs a clear failed run (non-zero, no fabricated
  before/after line) rather than no record at all.
- `journalctl -u bootc-fetch-apply-updates.service` and `-u svk-flatpak-update.service`
  survive a reboot (persistent journald drop-in took effect).

## 4. The rest of the ujust surface (`custom/ujust/`)

- `check-drift` on a freshly-built unmodified image reports **no** diffs (excludes
  tuned correctly) — then hand-edit one file under `/etc` and confirm it appears.
- `channel-status` reports the right channel/version/git-commit; `toggle-channel`
  actually switches and the machine boots the other channel's image.
- `luks-status` reports the TPM2 slot on an encrypted machine, and fails
  gracefully (not confusingly) on an unencrypted dev build with no crypttab entry.
- `device-info` / `bios-info` are useful and make **no network call**.
- `powerwash` refuses on anything but an exact hostname match, and
  `bootc install reset --experimental` is still the correct invocation for the
  pinned bootc version.
- `clean-flatpaks` behaves.
- Run **every** recipe as `admin` over real SSH, not a local root shell — the
  `pkexec`→`sudo` swap is the thing being tested.

## 5. Two judgment calls from 0cdaf5a worth a second look

- `just` was assumed to be in Fedora's own repos (no COPR needed). A wrong guess
  fails loudly at build time, so CI has probably already settled this — confirm.
- `/var/log/svk` was created `0750 root:root`, so every reader recipe needs
  `sudo`. Reasonable, but it was an implementation-time default, not a decision
  the spec pinned down.

## Note

Section 3's `gnome-software`-on-staff question from the original cadence spec is
**dead** — the single-image collapse answers it the other way round (staff get
`gnome-software` by design, gated by group rather than removed). Do not re-open it
from the archived spec.
