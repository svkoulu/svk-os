# Collapse svk-student + svk-staff into a single `svk-os`, and simplify CI

Status: **planned, no repo files touched.** Decisions below were settled in the
2026-07-26 review session. Two parts: A is a small CI cleanup, B is the real
work. A is independent and can land first.

Related, deliberately out of scope here:
- `20260726-1908-svk-check-health-service.md` — boot-time assertion service.
- `20260726-1908-server-strategy-and-pxe.md` — server image question + PXE.

---

## Part A — CI cleanup

**The tagging strategy does not change.** `:stable`, `:stable-<N>`,
`:stable-<N>-<DATE>`, `:testing`, `:latest`, `:testing-<DATE>` all stay. The
release-line segment `<N>` is kept deliberately — losing the tag in the version
string makes no sense.

The only change: **the weekly cron builds stable only.** The cron exists to get
new kernels and security fixes to *the fleet*; testing already rebuilds on every
push to main, which is when it is actually being worked on.

- `.github/workflows/build.yml`, `schedule)` case in the `setup` job: drop
  `do_testing=true`, keep `want_stable`.
- `README.md:128` currently says testing is built "(and weekly)" — update.
- No change to `build-images.yml`, the composite action, or `toggle-channel` in
  `svk-maintenance.just` (it reads `channel` from `image-info.json`, not `<N>`).

---

## Part B — one image, no flavors

### The decision

There is **no build-time flavor split**. One `svk-os` image ships everything.
The lockdown is scoped to the **account**, not the machine, and the **installer
decides which accounts exist**:

- lab machine → `opilas` + `admin`
- staff laptop → `staff` + `admin`

`admin` is on every machine either way.

**Why this works:** `files/student/etc/polkit-1/rules.d/49-school-lockdown.rules`
already gates on `subject.user == "opilas"`. The lockdown is inert on a machine
where opilas does not exist, so it can ship everywhere unconditionally. The
earlier plan (per-flavor trees in `/usr/share/svk/flavors/` + install-time
symlinks) is **dropped** — it solved a problem the polkit rules had already
solved.

**Result:** 4 images → 2 (`svk-os`, `svk-server`). Deleted: `Containerfile.student`,
`Containerfile.staff`, `build.student.sh`, `build.staff.sh`, the `BASE_IMAGE`
arg plumbing, the `needs: build-base` fan-out in `build-images.yml`, the
per-flavor os-release re-stamping, and `flatpaks/{student,staff}.list`.
`svk-base` stops being published as a consequence — nothing is left to share it
with, so no code sharing is lost.

**Tradeoff, accepted:** a lab machine and a staff laptop are no longer
distinguishable by image digest. The boundary moves from "this machine cannot do
X" to "this account cannot do X". That holds as long as the staff account has a
real password — see the placeholder note below.

### The one genuinely machine-scoped piece

`files/student/etc/dconf/profile/user` applies to **every** user on the machine,
so shipping it unconditionally would lock down staff too.

Fix: give opilas its own dconf profile via `DCONF_PROFILE=kiosk` in opilas's
`environment.d` — the account already has
`files/student/etc/skel/.config/environment.d/10-svk-locale.conf`, so the
mechanism is in place. **Verify** the variable is set before the session's dconf
service starts.

Everything else currently split per flavor — `tailscale.conf` `ENROLL`,
`resolved.conf.d` DNS, Firefox policy, the `bootc-fetch-apply-updates.timer`
cadence drop-in — is **per-site/per-machine config, not student-vs-staff**. It
belongs in `20260719-0110-usb-provisioning-config.md`, not in the image.

### Permission matrix

| app | admin | staff | opilas |
|---|---|---|---|
| `gnome-software` | yes | yes | no |
| `gnome-disks` | yes | no | no |
| `ptyxis` | yes | no | no |
| `gnome-system-monitor` | yes | no | no |
| `gnome-tweaks` | yes | no | no |
| `firewall-config` | yes | no | no |

**admin logs into the GUI.** It stays key-only over SSH (`sshd_config.d/
10-svk-hardening.conf:26`, `AllowGroups wheel`) and stays hidden from the greeter
— `svk-admin.conf` already assigns uid/gid **980**, below Fedora's `UID_MIN`, so
AccountsService filters it. Nothing to change there. Reaching the desktop is via
"Not listed?" at the greeter.

**Groups:**

- **wheel** — admin only (staff is deliberately excluded, see `build.staff.sh:8`;
  opilas is excluded in `svk-opilas.conf`). Used for the five admin-only apps.
- **staff** — new, declared in the base image's sysusers.d. The kickstart adds
  the staff user (`user --name=staff --groups=staff`); `m admin staff` puts admin
  in it too. Used for `gnome-software` and for the polkit grant below.

**Mechanism** — extend the existing pattern in `build/40-desktop.sh:26-28`, which
today is `chmod 700` + `rm -f <desktop>`:

- admin-only apps: `chgrp wheel` + `chmod 750`.
- `gnome-software`: `chgrp staff` + `chmod 750`.
- **Keep the `.desktop` files** — deleting them would leave admin with no
  launcher and no terminal to start one from.

**Hiding launchers per user.** `chmod 750` blocks execution, but a visible icon
that does nothing is a support call. Ship NoDisplay stub `.desktop` files under
`/usr/share/svk/hidden-apps/<set>/applications/` and select a set per user by
prepending it to `XDG_DATA_DIRS` in that user's `environment.d`:

- `wheel-only` set → the five admin-only apps. Used by staff.
- `opilas` set → those five plus `gnome-software`. Used by opilas.

Content stays in `/usr`, so image updates propagate; only the one-line
`environment.d` file is machine-local. This is the same reasoning that killed the
install-time-copy idea for flavor config. Same shadowing technique as 2fd4c12
(which was reverted for an unrelated reason — the flatpak it masked did not
exist).

### Staff flatpak installs

Staff must be able to install software **for students to use**, so the install
has to be **system scope** — a `--user` install lands in `~staff/.local/share/
flatpak`, which opilas cannot see and which the home reset would be irrelevant to
anyway.

System-scope installs need polkit auth for `org.freedesktop.Flatpak.app-install`,
which defaults to `auth_admin`. Staff has no sudo and is not in wheel, so this
currently fails. **Add a polkit rule granting `polkit.Result.YES` on
`org.freedesktop.Flatpak.app-install` and `runtime-install` to the `staff`
group** — narrow, and nothing else.

Consequences to accept:
- Teacher-installed apps are **per-machine**; installing on one lab machine does
  not put the app on the other 29. Fleet-wide additions belong in
  `flatpaks/common.list` + a rebuild.
- The installed app set is no longer known at build time, so no static blocklist
  can cover it. This is why opilas gets a **denylist**, not an allowlist —
  teacher-installed apps must work without further config. Teachers are trusted.
  If that ever needs tightening, malcontent's per-user app filter is the tool
  (the library is already kept for this — `build.student.sh:33`).
- `svk-flatpak-update.timer` already updates system-scope flatpaks, so
  teacher-installed apps stay patched.

**`build.staff.sh:8` must be rewritten, not just deleted.** It currently
justifies removing gnome-software on the grounds that terminal and SSH are
already closed to staff, making it "the one remaining avenue" for self-service
installs. Staff now get gnome-software by design; that rationale is retired.

### Package removals

Unconditional in the single image — none of these is a genuine conflict:

- `gnome-software` — **kept** (reversal of `build.staff.sh`). Staff and admin use it.
- `gnome-tour`, `malcontent-control` — removed for everyone. The **malcontent
  library stays** (per-user app filtering, held in reserve).
- `firefox` RPM — unchanged, still removed in `build/10-packages.sh`.

### Flatpak list

`flatpaks/common.list` becomes the only list; `student.list` and `staff.list` are
deleted. Final set (16, every ref verified against the Flathub API):

```
org.mozilla.firefox
org.gnome.TextEditor
org.gnome.Calculator
org.gnome.Papers
org.gnome.Loupe
org.gnome.FileRoller
org.libreoffice.LibreOffice
org.gimp.GIMP
org.inkscape.Inkscape
org.audacityteam.Audacity
org.videolan.VLC
org.gnome.gitlab.YaLTeR.VideoTrimmer
org.openshot.OpenShot
no.mifi.losslesscut
org.gtk.Gtk3theme.adw-gtk3
org.gtk.Gtk3theme.adw-gtk3-dark
```

**New:** Calculator, Papers, Loupe, FileRoller, Inkscape, Audacity, and the two
adw-gtk3 theme runtimes.

Rationale, verified against `workstation-ostree-config` `packages/silverblue.yaml`
(f44 branch — the config `quay.io/fedora-ostree-desktops/silverblue:44` is built
from): Silverblue ships `gnome-disk-utility`, `gnome-software`, `nautilus`,
`ptyxis`, `gnome-system-monitor` and `gnome-control-center`, and from
`common.yaml` only `unzip`. It ships **no** PDF viewer, image viewer,
file-roller, calculator or text editor. So:

- `org.gnome.TextEditor` is **not** a duplicate — it is the only text editor.
- Papers/Loupe/FileRoller/Calculator fill real gaps; without them a student
  cannot open a PDF, view an image, or extract an archive outside the CLI.
- No terminal flatpak: `ptyxis` is already in the base as an RPM (it replaced
  gnome-terminal as Fedora's default in F41 — GTK4, and container-aware for
  toolbx/distrobox, which is the point on an atomic desktop). It is restricted to
  wheel, not added.
- adw-gtk3 + adw-gtk3-dark because GIMP, Inkscape and Audacity are GTK3 flatpaks
  and do not pick up the host theme without them. Bluefin ships both for the same
  reason.

Neither upstream list contributed anything else. Bluefin's 39 entries
(`projectbluefin-common/.../homebrew/system-flatpaks.Brewfile`) are ~20 GNOME
core apps shipped as flatpaks *because Bluefin strips the RPMs* — svk keeps them
— plus a set svk deliberately blocks (Flatseal, ExtensionManager, Warehouse,
Bazaar, Impression, Refine, DistroShelf). Aeon's list
(`gnome-branding-Aeon/aeon-firstboot:31`) has the same character.

Record the never-add list as a comment in `common.list` so nobody adds them later.

### ISO

`iso/installer/build.sh` keeps its `FLAVOR` arg — it now selects **which
kickstart runs**, i.e. which accounts get created, not which image is installed.
`BASE_IMAGE` and `IMAGE_REF` become the same for both.

**Selection is a GRUB entry.** One ISO, two automated entries
(`inst.kickstart=…/svk-lab.ks` vs `…/svk-staff.ks`); the operator picks at boot.
No second device, no OEMDRV partition to manage.

Also in scope for the ISO, decided in the same session:

- Switch the automated entry to **`inst.cmdline`**. A kickstart gap then aborts
  visibly instead of parking on a WebUI page waiting for a click.
- Live-ISO debugging tools to add: `nmap`, `ncdu`, `bat`, `vim`, `ripgrep`, `jq`,
  `whois`, `traceroute`, `smartmontools`, `nvme-cli`, `ddrescue`, `testdisk`,
  `gparted`, `hwinfo`, `pciutils`, `usbutils`, `ethtool`, `tcpdump`,
  `efibootmgr`, `cryptsetup`, `btrfs-progs`, `tpm2-tools`. (`gdu` is not in
  Fedora; `ncdu` is.) `tpm2-tools` in particular is what lets a technician
  diagnose a failed LUKS/TPM enrollment on site.
- **Replace the `stafff` placeholder password** (`iso/installer/build.sh:244`).
  With the boundary now account-scoped rather than machine-scoped, a real staff
  password is load-bearing, not cosmetic. **Interim only** — the real fix is
  `20260719-0110-usb-provisioning-config.md`, which removes the baked password
  instead of substituting a better one. Don't treat this as closing the issue.
- The kickstart's staff `user` line needs **`--groups=staff`** for the new group
  above; the USB provisioning config's generated `user` line will need it too.

---

## Verify during implementation

1. `DCONF_PROFILE=kiosk` via `environment.d` actually takes effect before the
   session dconf service starts.
2. `XDG_DATA_DIRS` prepending correctly shadows `/usr/share/applications`
   entries for the app grid.
3. ISO size after six new flatpaks + two runtimes — LibreOffice, GIMP, Inkscape
   and Audacity are all large. Measure before and after.
4. `gnome-software` still functions for staff with `chmod 750` — it also runs as
   a background `--gapplication-service`, which will fail to start for opilas.
   Confirm that failure is quiet.
5. Fail closed: a machine with no `opilas` account must not silently end up with
   an unlocked kiosk profile. Confirm the lockdown is inert-not-absent.
