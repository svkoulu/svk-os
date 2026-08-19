# The first end-to-end install, in a VM — what it proved and what it broke

Status: **run 2026-08-19.** A locally-built ISO (no flatpaks, see below) was booted
under qemu with an emulated TPM 2.0, the automated LAB entry was installed
unattended, and the installed disk was inspected offline with libguestfs after a
real first boot. This is the first time anything in this repo has been observed
installing and booting.

Harness: `/home/kiuas/dev/.svk-vm/` (outside the repo, on real disk — the session
scratchpad is tmpfs and putting a 3 GB ISO in it exhausted host RAM). It should
become `ci/smoke-test.sh` — see `…-tier2-boot-smoke-test.md`.

## What worked, and is now evidence rather than hope

- **The ISO built rootless.** `iso/README.md` says the build needs a real host
  shell because `sudo podman` fails inside a distrobox. The installer image and
  Titanoboa both ran under plain rootless podman: Titanoboa's only escalation is
  one `podman run --cap-add sys_admin --mount type=image`, and mksquashfs runs
  `-all-root`. Worth revisiting the documented requirement.
- **Both automated GRUB entries work.** Entry 0 auto-selected after its 15 s
  timeout and installed the lab role with zero interaction. The `anaconda.target`
  entry from 685dc5b is fine; the 2026-07-21 `liveinst` failure does not recur.
- **The kickstart answers everything.** Finnish locale, `fi` keyboard, Helsinki
  time, automatic btrfs partitioning — no prompt at any point, and `inst.cmdline`
  never aborted, which means nothing was left unanswered.
- **The install is genuinely offline.** The deployment came from the ISO's own
  containers-storage.
- **The account model holds.** A lab install produced `opilas` (uid/gid 1002) and
  `admin` (uid 1000) and **no `staff`** — the fixed id map and the
  installer-decides-the-accounts design both behave as designed.
- **The update origin is right**: `ostree-image-signed:docker://ghcr.io/svkoulu/svk-os:stable`,
  i.e. signature enforcement is on from first boot.
- **GDM autologin for `opilas` is configured** and the role `%post` planted
  `DCONF_PROFILE=kiosk` + the `opilas` hidden-apps `XDG_DATA_DIRS` in `/etc/skel`.
- **All eleven units are enabled after first boot** (see below for the twist).
- **The power-profile fix works on real hardware-ish**: `svk-power-profile: set
  balanced (on_ac=1)` in the journal, over tuned-ppd's D-Bus API.

## What it broke — 1: the machine boots to a text console

**Anaconda writes `/etc/systemd/system/default.target -> multi-user.target` into
the installed system.** With an `ostreecontainer` payload there is no package
selection to infer a desktop from, so it takes the text default and overrides the
image's own `default.target -> graphical.target`.

Result: GDM is enabled, never starts, and the machine — lab or staff — comes up at
`fedora login:`. No autologin, no kiosk session, no desktop. Everything downstream
of a graphical session (the whole lockdown) is untestable on such a machine.

Nothing in the build or the image could have caught this: the image is correct and
the *installer* changes it afterwards. Only an install shows it.

**Fixed**: `svk-default-target.ks` runs `systemctl set-default graphical.target`,
included by both role kickstarts and by the interactive path. Not yet re-tested
end to end.

## What it broke — 2: `svk-claim-hostname` never runs

The unit carried `ConditionFirstBoot=yes` **and** a stamp-file condition. On an
Anaconda ostree install, `/etc/machine-id` is already populated by the time
systemd evaluates conditions, so **`ConditionFirstBoot` is never true** and the
unit is skipped on every boot, forever. The journal records it as
`skipped, unmet condition check ConditionFirstBoot=yes`, which reads exactly like
normal behaviour. The VM kept the hostname `fedora`.

This is the same shape of bug `../infra` hit with its Tailscale enrolment: a
condition that tests a proxy ("is this the first boot") instead of the actual
question ("has this machine ever claimed a name"). **Fixed** by deleting the
condition and keeping the stamp file, with the reasoning in the unit.

## The preset question, answered — and it is not what we assumed

`ConditionFirstBoot` was **not met on the first boot of a fresh install**, which
also means **systemd never applies first-boot preset policy on this install
path**. So the trap described in `…-unit-enablement-preset.md` does *not* fire for
svk-os installs: the eleven `/etc` symlinks laid down by the image survive
untouched, before and after first boot (verified both ways on the disk).

That changes the preset file's status from "fixes a live outage" to "insurance,
and cheap": `50-svk.preset` stays, because the day anything changes the install
path — `bootc install to-disk`, a `bootc-image-builder` disk, an image-mode
reinstall — the symlinks stop being the mechanism and the preset is what carries
enablement. Keep the CI cross-check for the same reason. But the alarming claim
in the earlier task file ("machines in the field may have been inert since
install") is **disproven for the EliteBook**, and that check can come off the
urgent list.

## Smaller things seen

- `systemd-remount-fs.service` **fails on every boot** (`/usr/bin/mount for /
  exited with exit status 32`) — Anaconda writes `ro` plus btrfs options for `/`
  in fstab and the remount is rejected. Harmless today, but it means a fresh
  install ships with a permanently failed unit, which is exactly the noise that
  hides a real failure later — and would need resolving before greenboot
  (`…-greenboot-rollback-safety.md`) is worth anything.
- The ISO for this run was built with **no flatpaks** (`flatpaks/common.list`
  all commented) to keep the installer image at ~9 GB instead of ~17 GB. So the
  offline flatpak bake, and everything about app availability, is **not** covered
  by this run.
- An empty flatpak list used to abort the ISO build outright (`grep -v` under
  `pipefail`); fixed while getting here.
- **The flatpak bake had no retry.** Rebuilding with the real 16-app set failed
  twenty minutes in on `[28] Timeout was reached` fetching one LibreOffice object,
  throwing away every app already downloaded. It is the only build-time network
  dependency in this repo that is not the registry — the thing CLAUDE.md's own
  rebuild-scope rule says to avoid. Now retried per app (3 attempts, backing off),
  which turns a blink into a pause but does not remove the dependency. Moving the
  set to first-boot installation from the LAN mirror does
  (`…-lan-mirror-flatpak-wiring.md`), and this is a second argument for it.
- `iso/build-iso.sh local` did not build a local ISO at all — the installer image
  pulled `:stable` from ghcr for its nested copy, so a "local" ISO installed
  ghcr's image, and the build failed while no such tag existed. Fixed by exporting
  the local image and loading it under the real ref.

## Next

- [ ] Re-run with the two fixes in and confirm a graphical session, autologin as
      `opilas`, and the kiosk lockdown actually in effect (`DCONF_PROFILE` before
      the session's first dconf read — still unproven)
- [ ] Re-run with the real flatpak set once, to cover the bake
- [ ] Re-enable FDE and run it again with the TPM (`…-fde-install-…-hardware.md`)
- [ ] Promote the harness to `ci/smoke-test.sh` + `ci/smoke-assert.sh`

---

## Update, same day — the graphical fix is proven, and a bigger thing fell out

**The default-target fix works.** An ISO rebuilt with `svk-default-target.ks` (and
the full 16-app flatpak set) installs and boots to a **Finnish GNOME desktop,
autologged in**, with Firefox, LibreOffice, Text Editor and Calculator in the dash
— i.e. the offline flatpak bake is on the machine and visible to the session.
Screenshot: `/home/kiuas/dev/.svk-vm/firstboot2.png`. That closes the worst of the
two install bugs and, with it, the first evidence that this project produces a
usable desktop.

**The `svk-claim-hostname` fix is NOT in that ISO**, and the reason matters more
than the fix:

### The pinned base digest had rotted out of the registry

`Containerfile.os` pinned
`quay.io/fedora-ostree-desktops/silverblue:44@sha256:b21b78d6…`. That digest **no
longer exists on quay.io** — `manifest unknown`. Every `podman build` of this repo
fails at the `FROM` line, and has done since quay pruned it.

Which means the **weekly CI rebuild has been failing**, and the weekly rebuild is
the entire mechanism by which new kernels and security fixes reach the fleet. This
is not a hypothetical any more: it is exactly the failure CLAUDE.md names as the
risk driving the project's design, it happened, and **nothing told anyone** —
there is still no `notify-on-failure` (`…-ci-failure-alerting.md`).

It was invisible locally too, because a cached copy of the old base sat in podman
storage; the first build after that cache was pruned is what surfaced it.

Two consequences worth acting on:

1. **Bumped the pin** to the current `:44` digest (`sha256:1d3b94de…`) so the repo
   builds again, with a comment at the `FROM` line saying why a pinned digest is
   not a stable artifact.
2. **Check whether Renovate is actually configured.** `CLAUDE.md` and `README.md`
   both say "Renovate keeps it current" and treat digest bumps as part of the
   security-update path, but there is **no `renovate.json` in this repo**. Either
   it is configured somewhere outside the repo, or the mechanism the docs rely on
   does not exist. Find out which — it is one of the two things standing between
   the fleet and a stale kernel, and the other one (CI alerting) is also missing.

### Correction to what I reported earlier today

The `just verify` run I reported as green after the unit fix was green against the
**previous** image — the rebuild had failed at `FROM` and left the old
`localhost/svk-os:latest` tag in place. The verification itself is fine; the image
it checked was stale. Re-run after the digest bump.

**Rebuild on the bumped digest: green.** `just build-os` succeeds on
`sha256:1d3b94de…`, `ci/verify-image.sh` passes every check against it (the one
WARN is the deliberate `SVK_LOCKDOWN=0` bring-up setting), and the
`svk-claim-hostname` fix is confirmed present in the image. It has still not been
*observed* on an install — that needs one more ISO+install cycle, which is the
same cycle the FDE re-enable needs, so pair them.
