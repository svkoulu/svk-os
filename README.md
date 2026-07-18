# svk — school bootc image factory

Builds and signs **four bootc OCI images** for a small school IT fleet and
publishes them to GHCR (`ghcr.io/svkoulu/...`). Machines are provisioned once from
an installer ISO, then track their image via automatic `bootc` updates.

These are *custom* images, so they do **not** inherit upstream security updates
automatically — the base is pinned by digest. A **weekly CI rebuild** is what pulls
in new kernels and fixes. If the pipeline silently breaks, the fleet silently stops
getting updates — that risk drives the design (`bootc container lint` as the final
build layer, `fail-fast: false`, and a recommended failure notification).

New here? Work through [`TODO.md`](TODO.md) for the one-time setup a human must do.

## Image hierarchy

```
quay.io/fedora-ostree-desktops/silverblue     (raw Fedora Silverblue, pinned by digest)
  └── svk-base      # Tailscale, mDNS, admin SSH, CLI tools, desktop defaults,
        │             power switching, certs, fwupd, ghcr mirror, cosign policy
        ├── svk-student   # locked kiosk: autologin (opilas) + home reset + dconf/polkit lockdown
        └── svk-staff     # normal desktop; staff install their own --user flatpaks

ghcr.io/ublue-os/ucore:stable
  └── svk-server    # pull-through registry cache + hostname dispenser + curated
                    # Flathub mirror + AdGuard Home DNS (independent; installed via Ignition)
```

The desktop apps (Firefox, LibreOffice, VLC, GIMP, video tools) are **Flatpaks
baked into the installer ISO** by Titanoboa, so first boot is fully offline and the
apps live in system scope (a student home-reset never loses them).

## Repo layout

```
Containerfile.{base,student,staff,server}   # one manifest per image
build/                                       # svk-base's numbered build scripts (dnf5, services, users, desktop)
build.{student,staff,server}.sh              # per-image build scripts
files/{base,student,staff,server}/           # static trees COPY'd to image "/"
flatpaks/{common,student,staff}.list         # flatpak sets baked into the ISOs
iso/                                         # Titanoboa ISO pipeline (build-iso.sh, hook-anaconda.sh)
server.bu                                    # Butane for the uCore server's first install
cosign.pub                                   # image-signing public key (private key is a repo secret)
Justfile                                     # local build + setup commands (`just`)
.github/workflows/build.yml                  # weekly / push / dispatch: builds all four
.github/workflows/iso.yml                    # manual: student/staff installer ISOs (Titanoboa)
archived/                                    # the previous FROM-bluefin implementation, for reference
```

## Build locally

### Dependencies

| Tool | Used for |
|---|---|
| `podman` | building every image |
| `just` | the build/setup recipes (run `just` to list them) |
| `cosign` | `just cosign-keygen` (generate the signing keypair) |
| `butane` | `just server-ign` (compile the uCore Ignition config) |
| `ShellCheck` | `just lint` (optional; lints the build scripts) |

`bootc` itself does **not** need to be installed on the host — it ships in the
base image, so the in-build `bootc container lint` just works.

Install on Fedora: `sudo dnf install podman just cosign butane ShellCheck`.
On openSUSE Tumbleweed: `sudo zypper install podman just cosign butane ShellCheck`.
On Debian/Ubuntu `just`/`butane`/`cosign` aren't in the default repos — see each
project's releases page (`butane` and `cosign` ship static binaries).

Building an **installer ISO** additionally needs a beefy host with root `podman`
and plenty of disk — it's heavy; prefer the `iso` CI workflow (see below).

```bash
just build-base                 # svk-base first — everything builds FROM it
just build-staff                # svk-staff  (FROM the local svk-base)
just build-student              # svk-student (FROM the local svk-base)
just build-server               # independent (uCore)
just build-desktops             # base + staff + student, in order
just build-all                  # all four
```

To build a derived image against the *pushed* base instead of a local one:
`just build-staff base_image=ghcr.io/svkoulu/svk-base:latest`.

CI builds the same images via `.github/workflows/build.yml` (which uses a composite
action, not this Justfile) and cosign-signs each with the `COSIGN_PRIVATE_KEY`
secret.

## Add / remove packages & apps

- **RPM packages** (system-wide, all desktops): edit the `dnf5 install` list in
  [`build/10-packages.sh`](build/10-packages.sh). `dnf5 install` is a no-op for
  anything Silverblue already ships. To *remove* a package Silverblue includes, add
  a `dnf5 remove -y <pkg>` (see how `build.student.sh` strips `gnome-tour` /
  `malcontent-control`).
- **Flatpak apps** (baked into the ISOs): edit `flatpaks/common.list` (shared) or
  `flatpaks/student.list` / `flatpaks/staff.list` (per-flavor). One app ID per line.
- **Firefox / uBlock Origin policy**: `files/{base,student,staff}/etc/firefox/policies/policies.json`
  (each image ships a full override — Firefox reads only one).

## Deploy / install the OS

**Desktops** — build an installer ISO and flash it (Titanoboa bakes the flatpaks in):

```bash
just iso student local          # or: staff ; or repo=ghcr to use the pushed image
# CI: Actions → iso → Run workflow → pick a flavor
```

Installing from that ISO lands the machine directly on `svk-student` / `svk-staff`,
pointed at the signed `:stable` ref for auto-updates — no manual `bootc switch`
needed. (You can also rebase an existing bootc system:
`sudo bootc switch ghcr.io/svkoulu/svk-<flavor>:stable`, or pin a release line with
`:stable-<N>`.)

### Channels

Two channels, ublue-style:

- **`:stable`** — what the fleet tracks. Built from **git tags** (cut a tag `N` → publishes `:stable`, `:stable-N`, `:stable-N-YYYYMMDD`). The weekly cron rebuilds the latest tag for security fixes **without** pulling in unreleased code, so the fleet stays patched but only advances features when you tag. Pin a machine to a release line with `:stable-N` (it won't auto-jump to `N+1`).
- **`:testing`** (alias `:latest`) — built from every push to `main` (and weekly). For test machines; carries `testing-YYYYMMDD` so a build is self-evidently a dev image.

The version (`stable-N-YYYYMMDD` / `testing-YYYYMMDD`) is identical across the image tag, os-release `IMAGE_VERSION`, the `org.opencontainers.image.version` label, `/usr/share/svk-os/image-info.json`, and the ISO filename.

**Server** — uCore installs via Ignition, not an ISO:

```bash
just server-ign                 # compiles server.bu (+ secrets/) -> server.ign
coreos-installer install /dev/sdX --ignition-file server.ign
```

Provisioning specifics — Tailscale enrolment (USB-delivered auth key), the hostname
dispenser, and the admin/jump-host SSH flow — are covered in
[`TODO.md`](TODO.md) and, in extended form, in
[`archived/README.md`](archived/README.md) (its runtime/networking/mirror/DNS
sections still describe the current server and network design; only its *build*
instructions are superseded by this file).

## More

- Design/architecture and build conventions: [`CLAUDE.md`](CLAUDE.md).
- The ISO pipeline and its open validation items: [`iso/README.md`](iso/README.md).
- The full rebuild plan and decisions: `tasks/todo/`.
