# Collapse svk-student + svk-staff into a single `svk-os`, and simplify CI

Status: **implemented 2026-07-27.** Both parts landed together. The spec below is
kept as written (it is the record of the decisions); read the
**Implementation notes** at the bottom first — five things came out differently
once the code met a real build, one of them a latent fleet bug this work
uncovered.

Verified: `svk-os` builds green through `bootc container lint --fatal-warnings`;
both kickstarts validate against `ksvalidator -v F44`; `systemd-sysusers` run
against the built image creates `admin` (1000) and `svk-staff` (481) and resolves
`/usr/bin/gnome-software` to `svk-staff`. **Nothing has been installed on
hardware or in a VM** — the runtime items (`DCONF_PROFILE`, `XDG_DATA_DIRS`,
ISO size) moved to `../todo/20260726-2315-hardware-validation.md`.

Decisions below were settled in the 2026-07-26 review session. Two parts: A is a
small CI cleanup, B is the real work.

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

---

## Implementation notes (2026-07-27)

Five deviations from the spec above, plus one bug found on the way.

### 1. The group is `svk-staff`, not `staff`

The spec called for a group named `staff`. That collides with the login account
of the same name: `useradd` refuses to create a user whose user-private group
already exists (*"group staff exists - if you want to add this user to that
group, use -g"*), which would abort the staff kickstart outright. Renamed to
`svk-staff`, matching the repo's existing `svk-` prefix convention. The kickstart
uses `--groups=svk-staff`.

### 2. Fixed GIDs, because the build-time `chgrp` can't wait for sysusers

`chgrp` in `build/40-desktop.sh` runs long before sysusers creates the group, so
it can only reference a number. The first attempt used 981 — which is
**`printadmin`** in the Silverblue base. The 959-999 band is entirely full
(Fedora's dynamic allocator counts *down* from 999 and has reached 959), so
`svk-staff` sits at **481**, in the empty 191-958 range.

`build/40-desktop.sh` now **asserts the gid is still free** and fails the build if
not. Without that, a future base image taking 481 would make sysusers silently
allocate a different gid, leaving gnome-software group-owned by whatever package
won — staff locked out, an unrelated group let in, nothing reporting it.

### 3. Latent bug found: `admin` was never actually on uid 980

The spec said of admin *"already assigns uid/gid 980 … Nothing to change there."*
That premise was false. A `u name <id>` sysusers entry claims the number as
**both** uid and gid, and gid 980 is `power` in the base — so sysusers discarded
980 entirely. Running `systemd-sysusers` against a built image:

```
Suggested user ID 980 for admin already used.
Creating user 'admin' (SVK-Admin) with UID 958 and GID 958.
```

admin's id was therefore *whatever happened to be free on that machine*. The
property svk actually depends on (below `UID_MIN`, so AccountsService hides it
from the greeter) held by luck, not design.

**Resolved a second time, after review:** rather than another system-range id, the
three human accounts now take the fleet's regular-user range, fixed on every
machine:

| id | account | created by |
|---|---|---|
| 1000 | `admin` | `sysusers.d`, first boot |
| 1001 | `staff` | staff kickstart, install time |
| 1002 | `opilas` | lab kickstart, install time |

Both kickstarts pin **uid and gid** (`group --gid=` before `user --uid= --gid=`),
because they run at install time — before sysusers creates admin — and an unpinned
`useradd` takes the lowest free id, which would be 1000. `build/30-users.sh`
asserts 1000 is free at build time.

The consequence: at uid 1000 admin is at/above `UID_MIN`, so AccountsService no
longer hides it automatically. It is now hidden **explicitly**, with
`SystemAccount=true` written to `/var/lib/AccountsService/users/admin` by
`files/os/etc/tmpfiles.d/svk-admin.conf` (`f+`, so a machine converges back to
hidden every boot). That file and the sysusers uid are a matched pair — change one
without the other and admin appears in the login screen.

### 4. Still open: admin has a locked password, so the GUI is unreachable

The spec's plan for the admin-only apps rests on *"admin logs into the GUI …
Reaching the desktop is via 'Not listed?' at the greeter."* But sysusers creates
admin with a **locked** password, and "Not listed?" is a password prompt. As
shipped, admin cannot start a local GUI session at all — which is also the reason
the spec gave for keeping the `.desktop` files rather than deleting them.

Not fixed here: the fix is either a provisioned password (USB provisioning
config's job) or accepting that the five admin apps are SSH/`sudo`-only. Tracked
in `../todo/20260726-2315-hardware-validation.md` §2.

### 5. Desktop ids are derived, not hardcoded — and it mattered immediately

`build/40-desktop.sh` finds each app's `.desktop` by grepping `Exec=`, and fails
the build if a restricted binary has no match. On the first build this caught
what a hardcoded list would have got wrong:

- System Monitor is `org.gnome.SystemMonitor.desktop` (**not**
  `gnome-system-monitor.desktop`), plus a second `gnome-system-monitor-kde.desktop`.
- Disks ships a second entry, `gnome-disk-image-writer.desktop`.
- gnome-software ships **five** entries (`org.gnome.Software.desktop` + four
  `gnome-software-local-file-*`).

Also learned: `gnome-tweaks` and `firewall-config` **are not in raw Silverblue**
at all. They stay in the matrix (harmless, and covered if they ever appear), but
the old code that "restricted" them was a no-op.

### 6. Per-site config that had nowhere else to go

The spec assigned `tailscale.conf`, DNS, Firefox policy and the update cadence to
the USB provisioning task. That task hasn't landed, so the image needs a
fleet-wide default in the meantime rather than a hole:

| what | fleet default now | note |
|---|---|---|
| Tailscale | `tag:svk-node`, `ENROLL="no"` | **behaviour change**: staff laptops no longer auto-enrol. Opt in by hand until USB provisioning lands (TODO.md §6). |
| DNS | server + NextDNS fallback, **one** profile (the stricter former student `76fc42`) | the two profiles can't be told apart machine-side any more |
| Firefox/uBO | the former **student** policy | strictest of the two; staff now get the Social lists too |
| Update cadence | **weekly** for everything | safe because the timer only *stages* — the service.d drop-in removes `--apply`, so the old student-monthly cadence was buying nothing |

### 7. One ISO, not two

The spec was internally inconsistent — *"`build.sh` keeps its `FLAVOR` arg"* vs
*"Selection is a GRUB entry … One ISO, two automated entries."* Took the latter:
`FLAVOR` is gone from the whole ISO pipeline, `iso/build-iso.sh` is now
`[repo] [channel]`, `iso.yml` has no matrix, and one `svk-os-<version>.iso` bakes
both kickstarts as GRUB entries 0 (lab, default) and 1 (staff). Building two
multi-GB ISOs that differ only in which kickstart a boot entry points at would
have been pure waste.

### 8. The staff password

Replaced `stafff` with an overridable build-arg (`STAFF_PASSWORD`, default
`svk-vaihda-tama`) **and** `chage -d 0 staff`, so the baked password is expired on
arrival and the teacher must set a real one at first login. This is a mitigation,
not the fix — as the spec says, `20260719-0110-usb-provisioning-config.md` removes
the baked password rather than improving it. Do not treat this as closed.

### Where the "verify during implementation" items went

1. `DCONF_PROFILE` ordering — **not verifiable without a session**; moved to the
   hardware-validation backlog, flagged as fail-OPEN (a miss means opilas gets an
   unlocked desktop, so check it first).
2. `XDG_DATA_DIRS` shadowing — same; the specific risk is flatpak's own
   user-environment generator, which runs *after* systemd's and appends, so the
   two are expected to compose. Unproven.
3. ISO size — needs an ISO build; moved.
4. gnome-software for staff under 0750 — group ownership verified in the built
   image; the quiet-failure question is a runtime one and moved. Note its
   autostart lives in `/etc/xdg/autostart`, which `XDG_DATA_DIRS` does not cover.
5. Fail-closed on a machine with no `opilas` — the mechanism is in place
   (`ExecCondition`, polkit user match, kickstart-created account) and the units
   are enabled; proving it needs an install, so it moved too.
