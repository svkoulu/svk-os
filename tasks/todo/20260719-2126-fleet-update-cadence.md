# Spec — per-flavor update cadence, manual override, and update logging

Status: **implemented in the working tree, not yet verified.** All resolved
decisions below are landed in code (see the Implementation outline for exact
files). No podman/buildah was available to actually build the images in the
session that implemented this, so **none of the Verification section below has
been run against a real build/VM yet** — treat this as "should be correct by
inspection + local `bash -n`/`just --list` checks" only, not "confirmed
working." Two implementation-time judgment calls worth a second look:
- `just` was assumed to be in Fedora's own repos (no COPR) — `dnf5 install`
  will fail loudly at build time if that's wrong, which is safe but untested
  here.
- `/var/log/svk` was created `0750 root:root`; `ujust update-status`/`device-info`
  etc. all read it via `sudo` accordingly — reasonable default, not something
  the spec originally pinned down.

## Context — why

Investigated adopting `uupd` (ublue-os's unified bootc+flatpak+brew+distrobox
updater) as a single trigger for the fleet. Conclusion (previous session): not
worth it — it'd only replace 2 of its 4 modules, adds `ublue-os/packages` COPR as
a second trust root outside svk's cosign-keyed chain, ships an `unconfined_t`
SELinux context and a permissive-by-default polkit rule. Going with native
`bootc-fetch-apply-updates.timer` + a small svk-owned flatpak-update unit instead.

Along the way, confirmed two things by reading `containers/bootc` upstream
directly (not assumption):

- `bootc-fetch-apply-updates.service` runs `bootc upgrade --apply --quiet` —
  `--apply` **reboots immediately** the moment an update is staged. This is the
  literal default; nothing currently overrides it.
- The desktop images (`svk-base`/`student`/`staff`) currently **never enable**
  `bootc-fetch-apply-updates.timer` at all — only `build.server.sh` does.
  `files/base/etc/systemd/system/bootc-fetch-apply-updates.timer.d/` and
  `uupd.timer.d/` both exist as jitter drop-ins for units that are either never
  enabled (bootc) or never installed (uupd) on desktops — dead weight from the
  old `FROM bluefin` build, tracked as an open gap in `TODO.md:134-136`.

Fleet shape driving the cadence decision: 20-30 machines, most (students) boot
2-3×/week, 3-4 (staff) boot ~daily. Network is present but flaky/slow — the LAN
mirror (`svk-server`) already absorbs the bandwidth problem; what's left to design
is *when* each machine checks/applies and whether a stale connection or a forced
reboot ever disrupts an active session.

## Resolved decisions

- **Two independent timers, not one unified pass**: image update (bootc) and
  flatpak update are separate concerns with different disruption profiles —
  flatpak update never requires a reboot, bootc update does. Splitting them means
  flatpaks can update more casually without touching the reboot-sensitive image
  path.
- **Image update cadence is per-flavor, set directly on the timer's own
  `OnCalendar=`** — no separate daily "check" layer sitting in front of it.
  `bootc upgrade` is already a no-op when there's nothing new, so a tighter check
  interval than the apply interval buys nothing. An operator who needs a fast
  path for a critical hotfix uses admin SSH and the manual trigger below, not a
  shortened timer.
  - **svk-student**: monthly. Rationale: locked-down kiosk (autologin, home reset
    every logout, curated/restricted app set, no free browsing) is genuinely
    lower risk than a staff desktop — slower patch cadence is an acceptable
    trade for far fewer disruptive windows on machines a class is actively using.
  - **svk-staff**: weekly, anchored **Monday**, base time before the school day
    starts (proposed `05:00`), **`RandomizedDelaySec=3h`** (window ends ~08:00).
- **Never force a reboot from the scheduled update path on desktops.** Override
  `bootc-fetch-apply-updates.service`'s `ExecStart=` to drop `--apply` (stage
  only: `/usr/bin/bootc upgrade --quiet`). The staged deployment applies at the
  machine's own next natural boot, not at the moment the timer fires. At
  monthly/weekly cadence, `Persistent=true` catch-up could otherwise land
  squarely on a boot that's mid-class or mid-workday — a forced reboot there is
  exactly the "unpredictable" outcome this whole exercise is trying to avoid.
  This override is common to all desktop flavors (base concern); only the timer
  *schedule* is per-flavor.
- **Fix the existing gap while touching this code**: `build/20-services.sh` gains
  `systemctl enable bootc-fetch-apply-updates.timer` (base, so it applies to all
  three desktop flavors uniformly); the dead `uupd.timer.d/` drop-in is deleted;
  the existing `bootc-fetch-apply-updates.timer.d/10-svk-randomize.conf` in
  `files/base/` is replaced by per-flavor drop-ins (see below) rather than one
  shared jitter value, since the schedules now differ by flavor.
- **Flatpak update is system-scope, weekly, both flavors** (student's baked set is
  system-owned per `CLAUDE.md`; staff's baked-common+staff set is too — see below,
  staff now has *no other* flatpak scope). A new `svk-flatpak-update.service`/
  `.timer` pair, shipped in `files/base/` (shared — same job for both flavors, no
  per-flavor override needed), runs `flatpak update -y` (system installations
  only). Runs the same Monday morning window as staff's image update
  (predictability: one known "update day" for the whole fleet), independent unit
  so it's not gated on the image job completing — flatpak update is unaffected by
  whether a bootc deployment is merely staged.
- **svk-server joins the same weekly Monday window as the desktops**
  (`OnCalendar=Mon *-*-* 05:00:00`, `RandomizedDelaySec=3h`) — one fleet-wide
  maintenance window is easier to reason about than a second schedule. Unlike
  the desktops it **keeps `--apply`** (forces reboot on update): a server is more
  likely to go a long time between organic reboots, so stage-and-wait could
  leave it un-patched far longer than intended, and a brief scheduled
  5am-Monday blip to mirror/DNS/cache is an acceptable, predictable cost since
  nothing else in the fleet is active then either.
- **Base time/jitter confirmed**: `05:00` + `RandomizedDelaySec=3h` for staff and
  server.
- **Student anchor confirmed**: `Mon *-*-1..7 05:00:00` (first Monday of the
  month, same time-of-day as staff/server) + `RandomizedDelaySec=1d`, keeping one
  consistent "update morning" flavor across the fleet even though frequency
  differs.
- **Staff is system-flatpaks-only — no `--user` flatpaks at all.** This wasn't
  really a live feature to begin with: `build/40-desktop.sh` already chmod-700s
  Ptyxis + strips its desktop entry for everyone but `admin` (written to cover
  `staff` explicitly, not just the student kiosk), staff has no SSH access
  (admin-key-only), and `custom/ujust/custom-apps.just` (which has an
  `install-flatpak` recipe) is unwired finpilot-template boilerplate — never
  `COPY`'d into any Containerfile or consolidated into the image. No real
  `--user` install path exists today despite `build.staff.sh`'s comment and
  `CLAUDE.md`'s hierarchy line both describing one; those should be corrected to
  say system-only. This spec's weekly system-flatpak job now covers **all**
  flatpaks on both flavors — no per-user update mechanism is needed.
- **Manual force-update trigger, reachable over admin SSH.** Bluefin ships a
  `ujust`-based maintenance Justfile for exactly this kind of on-demand
  operation; svk gets its own equivalent rather than adopting the real thing —
  ublue-os's `ujust` binary is itself a `ublue-os/bling` COPR package with `gum`
  as a runtime dependency (also not in Fedora's own repos), and pulling both in
  just to get a command name is the same class of new-trust-root trade-off
  already rejected for `uupd`. Instead: install Fedora's own `just` package (in
  Fedora's official repos, no COPR — verify at implementation time) and ship a
  thin `/usr/bin/ujust` wrapper (`exec just --justfile /usr/share/svk/svk.just
  "$@"`) so the command *feels* like the familiar ublue tool without the extra
  dependency. Recipes:
  - `ujust update-now` — trigger both update units immediately
    (`systemctl start bootc-fetch-apply-updates.service
    svk-flatpak-update.service`) — reuses the exact same units, wrapper
    scripts, and logging as the scheduled path, just run on demand. Stages only,
    same as the scheduled behavior — does **not** force a reboot.
  - `ujust update-apply-now` — same, but for the image update calls
    `bootc upgrade --apply --quiet` directly (bypassing the no-force-apply
    override) so it reboots immediately. Named separately and deliberately not
    the default, since an admin invoking this is consciously accepting the
    disruption right now — a fundamentally different situation from an
    unattended scheduled reboot landing mid-class.
  - `ujust update-status` — show the last recorded run (see logging below) for
    each unit plus `systemctl list-timers` output for the three update timers,
    so an admin can check fleet state over SSH without memorizing
    `journalctl`/`systemctl` invocations.
  - This also gives the existing dead `custom/ujust/` boilerplate (see above —
    unwired finpilot template files referencing Homebrew/JetBrains Toolbox,
    neither used by svk) a real purpose: replace those example files with the
    real `svk.just` and actually wire the consolidation step into the image
    build, instead of leaving unreferenced examples in the repo.
- **Update logging: durable, structured, survives the very reboot it might be
  logging.** Both update units call small svk-owned wrapper scripts instead of
  invoking `bootc`/`flatpak` directly — one code path whether triggered by the
  timer or by `ujust update-now`. Each wrapper records start/end timestamp,
  before/after state (image digest + `svk-os` version for the bootc wrapper;
  nothing app-by-app needed for flatpak, just success/failure is enough),
  duration, and exit status, and appends one line to a plain file at
  `/var/log/svk/update.log` — deliberately **not** journal-only, since `/var`
  is the persistent, writable part of an ostree/bootc system (survives updates
  and reboots by construction) whereas relying solely on journald's own
  persistence would be a second thing to get right, and the file format is
  trivially `tail`/`grep`-able over SSH without journalctl syntax. journald
  still captures the full raw command output automatically (systemd does this
  for any unit) — also set `Storage=persistent` in a journald drop-in so that
  detailed trace survives too, not just the one-line summary.
- **Fleet-maintenance recipes beyond update/status**, surveyed from
  `projectbluefin/common`'s own `ujust` files (`~/bluefin-repos/projectbluefin-common`)
  — most of what's there is desktop/dev-stack tooling that doesn't apply (Docker,
  VMs, Homebrew, JetBrains, Bazaar, Secure Boot/Nvidia key enrollment, gaming
  benchmarks), but these are a genuine fit and are added to `svk.just` alongside
  `update-*`:
  - `logs-this-boot` / `logs-last-boot` — `sudo journalctl --no-hostname -b 0` /
    `-b -1`. Straight copy, no adaptation needed.
  - `check-drift` (from upstream's `check-local-overrides`) — diffs `/usr/etc`
    vs `/etc` to surface config that's drifted from the shipped image defaults
    on one specific machine, with the same host-identity excludes upstream uses
    (machine-id, ssh host keys, hostname, fstab, etc.) plus svk-specific ones
    (`luks-bootstrap`, tailscale state). Fits directly: the whole point of a
    bootc fleet is uniform images, so silent local drift is exactly the failure
    mode worth a cheap diagnostic for.
  - `channel-status` / `toggle-channel` (from upstream's `toggle-testing`) —
    read the current channel/version/git-commit straight out of
    `/usr/share/svk-os/image-info.json` (already stamped by
    `stamp-os-release`, no new plumbing needed); toggle computes
    `ghcr.io/svkoulu/<image-name>:<stable|testing>` from the same file and runs
    `bootc switch --enforce-container-sigpolicy`. Lets an admin pilot a change
    on one machine outside the normal per-flavor schedule.
  - `luks-status` — **not** a wrapper around the existing
    `/usr/libexec/svk/luks-tpm-enroll` (that script is a first-boot-only,
    stamp-file-guarded one-shot; it no-ops once already enrolled). New, smaller
    logic: resolve the LUKS device from `/etc/crypttab` (same technique the
    enroll script uses) and report `systemd-cryptenroll --list <dev>` — read
    only, safe to run any time.
  - `device-info` (from upstream, **stripped of its external pastebin upload**)
    — `bootc status --verbose` + `flatpak list --columns=application,version,options`
    + `/usr/share/svk-os/image-info.json`, printed to stdout only. Upstream
    pipes this to a CentOS pastebin by default; that's an unnecessary external
    network dependency and a privacy problem for a school fleet, so it's cut
    entirely — the admin is already on the machine over SSH and can copy output
    directly.
  - `bios-info` — `dmidecode` manufacturer/product/BIOS version/release date.
    Cheap fleet-inventory value across 20-30 mixed/hand-me-down machines.
    Requires adding `dmidecode` to `build/10-packages.sh` (not currently
    installed).
  - `clean-flatpaks` — `flatpak uninstall --unused -y`, single confirm prompt.
    Clears orphaned runtimes left behind by flatpak updates.
  - `powerwash` — `bootc install reset --experimental` (upstream itself flags
    this `--experimental`; carry that caveat forward and verify it against
    svk's actual pinned bootc version before relying on it). Destructive, so
    gated behind a **typed-hostname confirmation** (`read -p` asking the admin
    to type the machine's own hostname back, not a simple y/N) rather than
    upstream's double `gum confirm` — same "make it hard to fat-finger"
    intent, no `gum` dependency. Useful for wiping/repurposing a machine that's
    still bootable and SSH-reachable, without needing the Titanoboa USB
    reinstall flow.
  - **`pkexec` → `sudo` throughout.** Upstream's recipes use `pkexec` for
    privileged steps, which depends on a polkit authentication agent — normally
    supplied by the GUI session (GNOME provides one). These recipes run over a
    **headless admin SSH session** with no such agent, so every adapted recipe
    uses `sudo` instead, matching admin's actual NOPASSWD-sudo permission model
    (`/etc/sudoers.d/10-svk-admin`).

## Open questions (not yet resolved — need your call before implementation)

1. **Close the one residual `--user`-install avenue: does `gnome-software` ship
   on staff, and can a non-admin session use it to add a flatpak remote?**
   Flatpak's `--user` installs need **zero privilege** by design — no polkit gate
   the way system-scope installs have — so "staff can't sudo" doesn't by itself
   prevent a self-service install. The backstop has to be "staff has no UI
   capable of adding a remote or invoking `flatpak install`," not a permission
   check. svk doesn't currently exclude `gnome-software` the way it excludes the
   RPM Firefox, and whether its repository-management UI is reachable without
   admin rights on the shipped Fedora version is unconfirmed. Needs a quick
   check on a built image — or, simpler, exclude `gnome-software` outright in
   `build.staff.sh` if you'd rather not rely on its UI restricting this,
   consistent with the fleet already having no app-store path (flatpaks are
   baked, not browsed/installed at runtime).

## Implementation outline (for the follow-up task)

1. `build/20-services.sh` — add `systemctl enable
   bootc-fetch-apply-updates.timer` and `systemctl enable
   svk-flatpak-update.timer`.
2. `files/base/etc/systemd/system/bootc-fetch-apply-updates.service.d/10-svk-no-force-apply.conf`
   — clear + reset `ExecStart=` to drop `--apply` (stage only). Applies to all
   three desktop flavors.
3. Delete `files/base/etc/systemd/system/uupd.timer.d/` and the current shared
   `bootc-fetch-apply-updates.timer.d/10-svk-randomize.conf` (superseded by
   per-flavor drop-ins below).
4. `files/student/etc/systemd/system/bootc-fetch-apply-updates.timer.d/10-svk-schedule.conf`
   — `OnCalendar=Mon *-*-1..7 05:00:00`, `RandomizedDelaySec=1d`, `Persistent=true`.
5. `files/staff/etc/systemd/system/bootc-fetch-apply-updates.timer.d/10-svk-schedule.conf`
   — `OnCalendar=Mon *-*-* 05:00:00`, `RandomizedDelaySec=3h`, `Persistent=true`.
6. `files/server/etc/systemd/system/bootc-fetch-apply-updates.timer.d/10-svk-schedule.conf`
   — `OnCalendar=Mon *-*-* 05:00:00`, `RandomizedDelaySec=3h`, `Persistent=true`;
   keeps `--apply` (no service override on server).
7. New unit pair, `files/base/etc/systemd/system/svk-flatpak-update.service` +
   `.timer` (`OnCalendar=Mon *-*-* 05:00:00`, `RandomizedDelaySec=3h`;
   `Restart=on-failure` given the flaky link), `ExecStart=` pointing at the new
   `svk-update-flatpak` wrapper (item 10) from the start.
8. `build.staff.sh` — drop the stale "staff install their own `--user` flatpaks"
   comment; decide + apply the `gnome-software` exclusion from Q1 above if going
   that route. `CLAUDE.md`'s hierarchy line for `svk-staff` needs the same
   correction (currently says "staff install their own `--user` flatpaks").
9. `TODO.md` — update the stale "which updater is active?" verification item
   (§ around line 134) to check the new per-flavor timers instead.
10. `files/base/usr/libexec/svk/svk-update-image` (new) — wraps
    `bootc upgrade --quiet`; records before/after image digest + `svk-os`
    version (`bootc status --format=json`), duration, exit status; appends one
    line to `/var/log/svk/update.log`. Referenced by both
    `10-svk-no-force-apply.conf` (item 2, `ExecStart=` points here instead of
    raw `bootc`) and `ujust update-now`.
11. `files/base/usr/libexec/svk/svk-update-flatpak` (new) — same pattern,
    wraps `flatpak update -y`, appends to the same log file.
12. `files/base/etc/tmpfiles.d/svk-update-log.conf` (new) — creates
    `/var/log/svk` at boot (same idiom as the existing `svk-admin.conf`
    tmpfiles entry).
13. `files/base/etc/systemd/journald.conf.d/10-svk-persistent.conf` (new) —
    `Storage=persistent`.
14. `custom/ujust/` — delete `custom-apps.just`/`custom-system.just`
    (unwired finpilot boilerplate referencing Homebrew/JetBrains Toolbox, unused
    by svk); add `custom/ujust/svk-update.just` (the three update recipes) and
    `custom/ujust/svk-maintenance.just` (`logs-this-boot`, `logs-last-boot`,
    `check-drift`, `channel-status`, `toggle-channel`, `luks-status`,
    `device-info`, `bios-info`, `clean-flatpaks`, `powerwash`).
15. New build step (base) — install Fedora's own `just` package (confirm it's
    in Fedora's repos, not a COPR, before relying on this), consolidate
    `custom/ujust/*.just` into `/usr/share/svk/svk.just`, and ship
    `/usr/bin/ujust` as a one-line `exec just --justfile
    /usr/share/svk/svk.just "$@"` wrapper. This is genuinely new — today
    nothing consolidates `custom/ujust/` into the image at all.
16. `build/10-packages.sh` — add `dmidecode`.

## Verification (for the implementation task)

- `systemctl list-timers` on a built image of each flavor: confirm
  `bootc-fetch-apply-updates.timer` and `svk-flatpak-update.timer` are enabled
  with the expected per-flavor `OnCalendar`/`RandomizedDelaySec`.
- `systemctl cat bootc-fetch-apply-updates.service` on each flavor: confirm the
  effective `ExecStart=` has no `--apply` on desktops, still has it on server.
- Force a stage-only update on a test VM (`bootc upgrade --quiet` manually);
  confirm the machine keeps running on the old deployment until a subsequent
  reboot, then boots into the new one.
- Confirm `svk-flatpak-update.service` updates system flatpaks without touching
  any `--user` installations, and survives one simulated network failure via its
  `Restart=` policy.
- `ujust update-now` on a test VM: both units start, `/var/log/svk/update.log`
  gets a new correct line (before/after version, exit 0, plausible duration),
  machine does **not** reboot.
- `ujust update-apply-now`: image update applies and the machine reboots; the
  log line for that run is present and correct on the **other side** of the
  reboot (proves `/var/log/svk` persistence, not just journald).
- `ujust update-status`: output matches the log file's last lines and
  `systemctl list-timers` for all three update timers.
- Simulate a network failure mid-update: confirm the wrapper logs a clear
  failed run (non-zero exit, no fabricated "before/after" line) rather than
  silently producing no record.
- Confirm `journalctl -u bootc-fetch-apply-updates.service` and
  `-u svk-flatpak-update.service` survive a reboot (persistent journald
  drop-in took effect).
- `ujust check-drift` on a freshly-built, un-modified image: confirm it reports
  **no** diffs (excludes are correctly tuned) — then hand-edit one file under
  `/etc` and confirm it shows up.
- `ujust channel-status` reports the correct channel/version/git-commit; `ujust
  toggle-channel` on a test VM actually switches and the machine boots the
  other channel's image.
- `ujust luks-status` on an encrypted test VM correctly reports the TPM2 slot;
  on an unencrypted dev build it fails gracefully (no crypttab entry) rather
  than erroring confusingly.
- `ujust device-info` / `bios-info`: confirm output is useful and **nothing
  leaves the machine** (no network call).
- `ujust powerwash`: confirm it refuses to proceed on anything other than an
  exact hostname match, and that `bootc install reset --experimental` is still
  the correct invocation for svk's pinned bootc version.
- Run every recipe as the `admin` user over actual SSH (not a local root
  shell) to confirm the `pkexec`→`sudo` swap holds up end to end.

## Out of scope

Firmware updates (`fwupd-refresh.timer` ships enabled by Fedora already,
untouched by this spec); any change to the weekly CI build/publish cadence
(`build.yml`) — that's supply, this spec is demand; deeper GNOME-lockdown work
beyond the `gnome-software` question in Q1 (e.g. terminal-escape vectors through
other apps) if that check turns up more than expected — would become its own
follow-up task.
