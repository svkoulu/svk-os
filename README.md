# svk-os — school bootc desktop image factory

Builds and signs the **bootc OCI desktop image** for a small school IT fleet and
publishes it to GHCR (`ghcr.io/svkoulu/svk-os`). Machines are provisioned once from
an installer ISO, then track the image via automatic `bootc` updates.

This is a *custom* image, so it does **not** inherit upstream security updates
automatically — the base is pinned by digest. A **weekly CI rebuild** is what pulls
in new kernels and fixes. If the pipeline silently breaks, the fleet silently stops
getting updates — that risk drives the design (`bootc container lint` as the final
build layer, `fail-fast: false`, and a recommended failure notification).

New here? Work through [`TODO.md`](TODO.md) for the one-time setup a human must do.

## The image

```
quay.io/fedora-ostree-desktops/silverblue     (raw Fedora Silverblue, pinned by digest)
  └── svk-os        # THE desktop image — every lab machine and staff laptop.
                    # Tailscale, mDNS, admin SSH, CLI tools, desktop defaults, power
                    # switching, certs, fwupd, ghcr mirror, cosign policy, AND the
                    # kiosk lockdown (autologin target, home reset, dconf/polkit).
```

The **server** (`svk-server`: LAN registry cache, hostname dispenser, Flathub mirror,
AdGuard Home DNS — built FROM uCore, installed via Ignition) moved to its own repo on
2026-07-27: [`../svk-server`](../svk-server). It never shared build code with this
image. The `svk-server.local` references still in `files/os/` are the **client** side
— runtime LAN facts, not a build dependency.

**One image, no flavors.** A lab machine and a staff laptop run the same bytes; the
**installer** decides which accounts exist (`opilas` + `admin` vs `staff` + `admin`),
and the lockdown is scoped to the `opilas` **account**, so it ships everywhere and is
simply inert where that account was never created. The boundary is "this account
cannot do X", not "this machine cannot do X" — which is why the staff account's
password is load-bearing. Who can run what:

| app | admin | staff | opilas |
|---|---|---|---|
| `gnome-software` | yes | yes | no |
| `gnome-disks` | yes | no | no |
| `ptyxis` (Terminal) | yes | no | no |
| `gnome-system-monitor` | yes | no | no |
| `gnome-tweaks`† | yes | no | no |
| `firewall-config`† | yes | no | no |

† not shipped by Silverblue 44; listed so they're covered automatically if that changes.

Enforced by group ownership + mode `0750` on the binaries (`wheel` for the admin-only
five, `svk-staff` for gnome-software), with per-account `NoDisplay` stubs prepended to
`XDG_DATA_DIRS` so the icons disappear too. The three accounts have fixed ids on every
machine — `admin` 1000, `staff` 1001, `opilas` 1002 — and `admin` is kept out of the
login screen's user list with `SystemAccount=true`, since at uid 1000 it is no longer
filtered automatically. Staff can install Flatpaks **system-wide**
(a narrow polkit grant), because an app installed for students to use has to land
somewhere `opilas` can see.

The desktop apps (Firefox, LibreOffice, VLC, GIMP, Inkscape, video tools) are
**Flatpaks baked into the installer ISO** by Titanoboa, so first boot is fully offline
and the apps live in system scope (a student home-reset never loses them).

## Repo layout

```
Containerfile.os                             # the image manifest
build/                                       # numbered build scripts (dnf5, services, users, desktop)
files/os/                                    # static tree COPY'd to image "/"
flatpaks/common.list                         # the flatpak set baked into the ISO
iso/                                         # Titanoboa ISO pipeline (build-iso.sh, installer/)
cosign.pub                                   # image-signing public key (private key is a repo secret)
Justfile                                     # local build + setup commands (`just`)
.github/workflows/build.yml                  # weekly / push / dispatch: builds the image
.github/workflows/iso.yml                    # the installer ISO (Titanoboa)
archived/                                    # the previous FROM-bluefin implementation, for reference
```

## Build locally

### Dependencies

| Tool | Used for |
|---|---|
| `podman` | building the image |
| `just` | the build/setup recipes (run `just` to list them) |
| `cosign` | `just cosign-keygen` (generate the signing keypair) |
| `ShellCheck` | `just lint` (optional; lints the build scripts) |
| `git` | `just iso` (clones the pinned Titanoboa) |
| `rsync` | `just iso` (copies the Titanoboa clone into `iso/.build/`) |

`bootc` itself does **not** need to be installed on the host — it ships in the
base image, so the in-build `bootc container lint` just works.

Install on Fedora: `sudo dnf install podman just cosign ShellCheck git rsync`.
On openSUSE Tumbleweed: `sudo zypper install podman just cosign ShellCheck git rsync`.
On Debian/Ubuntu `just`/`cosign` aren't in the default repos — see each
project's releases page (`cosign` ships a static binary).

Building an **ISO** (`just iso`) has two extra requirements beyond the table
above — see `iso/README.md` for the full list.

Building an **installer ISO** additionally needs a beefy host with plenty of disk
(~45 GB) — it's heavy; prefer the `iso` CI workflow (see below). It needs **no
root and no `sudo`**, and works from inside a toolbox/distrobox.

```bash
just build-os                   # the desktop image
```

CI builds the same image via `.github/workflows/build.yml` (which uses a composite
action, not this Justfile) and cosign-signs each with the `COSIGN_PRIVATE_KEY`
secret.

### Verify a build

```bash
just verify                     # tier 1: static checks against localhost/svk-os:latest
```

`ci/verify-image.sh` asserts the things whose failure is otherwise invisible until
a machine is wrong: that every unit we enable survives **first-boot preset
policy** (see below), that the kiosk dconf db compiled with its locks in it, that
the baked `cosign.pub` matches this repo's, that no `--apply` survives on the
desktop update path, and that every command the shipped scripts call is actually
installed. CI runs it after the build and **before** the push, so a failure does
not publish. It does not prove the machine boots — that is tier 2, which does not
exist yet (`tasks/todo/…-tier2-boot-smoke-test.md`).

**Units are enabled in two places on purpose.** `build/20-services.sh` runs
`systemctl enable` (symlinks in `/etc`, which is what keeps already-installed
machines running) and `files/os/usr/lib/systemd/system-preset/50-svk.preset`
lists the same units (which is what survives the first boot of a fresh `/etc`,
where preset policy would otherwise disable all but one of them). Removing either
list breaks a different set of machines; `just verify` fails if they disagree.

## Add / remove packages & apps

- **RPM packages** (system-wide): edit the `dnf5 install` list in
  [`build/10-packages.sh`](build/10-packages.sh). `dnf5 install` is a no-op for
  anything Silverblue already ships; to *remove* one it includes, add it to the
  removal loop at the top of the same file (that's how `gnome-tour`,
  `malcontent-control` and the RPM Firefox go).
- **Flatpak apps** (baked into the ISO): edit `flatpaks/common.list`. One app ID per
  line — it carries a **never-add** list at the top, read that before adding.
- **Who can run an app**: the matrix in [`build/40-desktop.sh`](build/40-desktop.sh)
  (group + mode on the binary, plus the hidden-launcher sets).
- **Firefox / uBlock Origin policy**: `files/os/etc/firefox/policies/policies.json`
  (one policy for the fleet — Firefox reads exactly one, and it is machine-scoped).

## Deploy / install the OS

**Desktops** — build the installer ISO and flash it (Titanoboa bakes the flatpaks in):

```bash
just iso local                  # or repo=ghcr to use the pushed image
just run-iso                    # boot that ISO in a throwaway VM to test the installer
# CI: Actions → iso → Run workflow → pick a channel
```

**One ISO for the whole fleet.** It bakes both role kickstarts; the operator picks at
boot from the GRUB menu:

| entry | what it creates |
|---|---|
| `Install … - LAB machine (opilas kiosk)` *(default)* | `opilas` (locked password, autologin, kiosk dconf profile) + `admin` |
| `Install … - STAFF laptop` | `staff` (normal login, `svk-staff` group, password expired at first login) + `admin` |
| `Live desktop` (×2) | no install — a full live session with the on-site repair kit |

Both install entries are automated and **erase the disk**. Installing lands the
machine directly on `svk-os`, pointed at the signed `:stable` ref for auto-updates —
no manual `bootc switch` needed. (You can also rebase an existing bootc system:
`sudo bootc switch ghcr.io/svkoulu/svk-os:stable`, or pin a release line with
`:stable-<N>`.)

### Channels

Two channels, ublue-style:

- **`:stable`** — what the fleet tracks. Built from **git tags** (cut a tag `N` → publishes `:stable`, `:stable-N`, `:stable-N-YYYYMMDD`). The weekly cron rebuilds the latest tag for security fixes **without** pulling in unreleased code, so the fleet stays patched but only advances features when you tag. Pin a machine to a release line with `:stable-N` (it won't auto-jump to `N+1`).
- **`:testing`** (alias `:latest`) — built from every push to `main`. For test machines; carries `testing-YYYYMMDD` so a build is self-evidently a dev image. The weekly cron deliberately does **not** rebuild it: testing already rebuilds whenever it's being worked on, and the cron exists to get security fixes to the *fleet*.

The version (`stable-N-YYYYMMDD` / `testing-YYYYMMDD`) is identical across the image tag, os-release `IMAGE_VERSION`, the `org.opencontainers.image.version` label, `/usr/share/svk-os/image-info.json`, and the ISO filename. It's also folded into os-release `PRETTY_NAME` (e.g. `SVK OS (testing-20260719)`) and the ISO's GRUB boot-menu entry, since PRETTY_NAME is the one field the Anaconda WebUI installer and GNOME's About page actually display.

**Server** — see [`../svk-server`](../svk-server); uCore installs via Ignition, not
an ISO.

Provisioning specifics — Tailscale enrolment (USB-delivered auth key), the hostname
dispenser, and the admin/jump-host SSH flow — are covered in
[`TODO.md`](TODO.md) and, in extended form, in
[`archived/README.md`](archived/README.md) (its runtime/networking/mirror/DNS
sections still describe the current server and network design; only its *build*
instructions are superseded by this file).

## Signing key

Every image is cosign-signed with the keypair in `cosign.pub` / `cosign.key`
(private half gitignored, held in the `COSIGN_PRIVATE_KEY` repo secret). The
public half is baked into every image and enforced on every machine via
`/etc/containers/policy.json` + `registries.d`.

### Backup

**`COSIGN_PRIVATE_KEY` in GitHub is write-only — you cannot read it back out.**
If the local `cosign.key` is lost, the key is gone, and *nothing breaks
immediately*: CI keeps signing, the fleet keeps updating, and you only discover
the loss on the day you need to rotate or re-sign. Keep the key **and** its
`COSIGN_PASSWORD` backed up offline, outside GitHub.

### Rotation

Rotation is awkward because the trust anchor lives inside the artifact being
replaced. A machine that misses the transition rejects every image signed
afterwards and needs a USB reinstall or physical console access. The sequence:

1. Generate the new keypair.
2. Build an image **signed with the old key** whose `policy.json` accepts
   **either** public key, shipping both.
3. Publish it, and wait until **every** machine has updated to it.
   **Verify this — do not assume.** (This step is why
   `tasks/todo/20260726-1908-svk-check-health-service.md` is a prerequisite for
   safe rotation: it needs per-machine "last successful upgrade" state.)
4. Only then start signing with the new key alone.
5. Later, ship an image (signed with the new key) that drops the old public key.

Step 3 is not skippable.

Rotate on suspected compromise or staff departure — not on a calendar. The
rotation itself carries more fleet risk than an unrotated key sitting in a repo
secret.

## More

- Design/architecture and build conventions: [`CLAUDE.md`](CLAUDE.md).
- The ISO pipeline and its open validation items: [`iso/README.md`](iso/README.md).
- The full rebuild plan and decisions: `tasks/todo/`.
