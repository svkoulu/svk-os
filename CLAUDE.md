# svk — school bootc image factory

## Purpose

Builds and signs **four bootc OCI images** for a small school IT fleet, publishes them to GHCR (`ghcr.io/svkoulu/...`). Machines are provisioned once from an installer ISO, then track their image via automatic `bootc` updates. Because these are custom images, the base is pinned by digest and does **not** inherit upstream updates automatically — a weekly CI rebuild (+ Renovate digest bumps) is what pulls in new kernels/security fixes. A silently broken pipeline means the fleet silently stops getting updates; that risk drives most of the design (`bootc container lint --fatal-warnings` as final layer, `fail-fast: false`, notify-on-failure).

## Image hierarchy

```
quay.io/fedora-ostree-desktops/silverblue   (raw Fedora Silverblue, pinned by DIGEST)
  └── svk-base       # Tailscale, mDNS, admin SSH, CLI tools, desktop defaults,
        │              power switching, certs, fwupd, ghcr mirror, cosign policy
        ├── svk-student   # locked kiosk: autologin (opilas) + home reset + dconf/polkit lockdown
        └── svk-staff     # normal desktop, no kiosk lockdown; system-scope flatpaks only (no gnome-software, no terminal/SSH)

ghcr.io/ublue-os/ucore:stable
  └── svk-server     # pull-through registry cache + hostname dispenser + curated Flathub
                     # mirror + AdGuard Home DNS (independent, provisioned via Ignition/Butane, not bootc switch)
```

Rebuilt (2026-07) the **modular way**: `svk-base` is raw Silverblue + svk's own config, **not** `FROM ghcr.io/ublue-os/bluefin`. Raw `Containerfile`s (ublue `image-template` lineage), not BlueBuild — this is what lets a single workflow build both the Silverblue desktops and the uCore server. See `tasks/todo/…-modular-base-rebuild-*` for the rebuild rationale and decisions.

The desktop **apps** (Firefox, LibreOffice, VLC, GIMP, video tools) are **Flatpaks baked into the installer ISO** by Titanoboa — not installed at build time, and not at first boot. First boot is fully offline; the apps live in system scope (`/var/lib/flatpak`), so a student home-reset never loses them. Ongoing flatpak updates come from the server's LAN Flathub mirror.

## Directory structure

```
Containerfile.{base,student,staff,server}   # one manifest per image
build/                                       # svk-base's build scripts, run in order:
  00-image-info.sh                           #   branding -> stamps os-release + svk-os/image-info.json (via the shared stamper)
  10-packages.sh                             #   dnf5 installs (tailscale repo, CLI, mDNS); excludes RPM Firefox
  20-services.sh                             #   systemctl enable (sshd, avahi, tailscale, power, hostname)
  30-users.sh                                #   admin account (sysusers.d) + sudoers + ssh perms
  40-desktop.sh                              #   dconf, app-restriction chmods, CA trust
  clean-stage.sh / copr-helpers.sh           #   build-artifact cleanup / COPR helpers
build.{student,staff,server}.sh              # per-image scripts for the derived + server images
files/{base,student,staff,server}/           # static trees COPY'd to image "/"
flatpaks/{common,student,staff}.list         # flatpak sets baked into the ISOs (per flavor)
iso/                                         # Titanoboa ISO pipeline (build-iso.sh, hook-anaconda.sh)
custom/                                      # ujust recipes shipped into the image
server.bu                                    # Butane for the uCore server's first install
cosign.{pub,key}                             # image-signing keypair (.key gitignored)
secrets/                                     # server-install secrets (gitignored)
archived/                                    # the previous FROM-bluefin implementation, for reference
Justfile                                     # local build + setup commands (CI does NOT use it)
.github/actions/build-image/                 # shared build+sign+push composite action
.github/workflows/build.yml                  # router: picks channel(s) per event (git tag/main/cron/dispatch)
.github/workflows/build-images.yml           # reusable: builds all four for one channel from one ref
.github/workflows/iso.yml                    # manual: student/staff installer ISOs (Titanoboa)
```

`Containerfile.base` is **multi-stage**: a `scratch` `ctx` stage gathers `build/` + `custom/`, then the final stage is Silverblue-pinned-by-digest; build logic runs via `RUN --mount=type=bind,from=ctx …` calling each `build/NN-*.sh`, then `clean-stage.sh`, then `bootc container lint --fatal-warnings`. The **derived** manifests (`Containerfile.{student,staff}`) stay thin: `FROM ${BASE_IMAGE}` → `COPY files/X/` → `RUN build.X.sh` → lint. Keep base's install/config logic in the numbered `build/` scripts, and each derived image's logic in its `build.X.sh` — not in the Containerfile.

## Build strategy

- **Layering**: `svk-base` is built and pushed first; `svk-student`/`svk-staff` build `FROM ${BASE_IMAGE}` — in CI the exact svk-base built that run (`base_from`/immutable tag), locally `localhost/svk-base` (overridable via `--build-arg BASE_IMAGE=…`). `svk-server` is independent (uCore).
- **Local build order**: base → (staff, student); server anytime. Use the Justfile:
  ```bash
  just build-base                 # svk-base first
  just build-staff                # FROM the local svk-base (or base_image=ghcr.io/svkoulu/svk-base:latest)
  just build-student
  just build-server               # independent (uCore)
  just build-all
  ```
- **Packages use `dnf5`**, not `rpm-ostree install` (`dnf5 config-manager setopt keepcache=1 install_weak_deps=0`; `dnf5 install -y`), with `--mount=type=cache` for the dnf cache. On a raw Silverblue base most of the old idempotency guards are unnecessary (the packages aren't already present) — keep a guard only where a package might already ship. To *remove* a Silverblue default, add `dnf5 remove -y <pkg>` (e.g. student strips `gnome-tour` / `malcontent-control`; base excludes the RPM Firefox so only the Flatpak ships).
- **CI**: `.github/workflows/build.yml` is a thin router — its `setup` job decides which channel(s) to build per event (git tag → stable, push to main → testing, weekly cron → **both**, dispatch → choice) and computes the date + stable ref, then calls the reusable `.github/workflows/build-images.yml` once per channel. The reusable workflow fans out base → derived (`needs: build-base`, built FROM the base built that run) + independent server, via the shared `build-image` composite action. Each desktop job ends in `bootc container lint --fatal-warnings`; server uses plain `bootc container lint` (a base we don't control). `fail-fast: false` so one image's failure doesn't hide the others'.
- **Versioning / channels** (ublue-style): two channels, each a rolling tag + immutable dated pins.
  - **stable** (from **git tags**): `:stable` (rolling, all lines), `:stable-<N>` (rolling within release line N), `:stable-<N>-<DATE>` (pinned). **The fleet tracks `:stable`** — or `:stable-<N>` to pin a line.
  - **testing** (from **main**): `:testing`, `:latest` (alias), `:testing-<DATE>` (pinned). Dev/test.
  - The **weekly cron builds both**: stable **rebuilt from the latest git tag** (security only — no unreleased code reaches the fleet) + testing from main. New features reach stable only when you cut a tag.
  - One version string — `stable-<N>-<DATE>` or `testing-<DATE>` (e.g. `stable-1-20260718`) — flows into the image tag, os-release `IMAGE_VERSION`, the `org.opencontainers.image.version` label, `/usr/share/svk-os/image-info.json`, and the ISO filename. `channel`/`major`/`date` are computed once in `setup` and passed down so base + derived agree; the composite action assembles the tags. os-release + the JSON are stamped by the shared `files/base/usr/libexec/svk/stamp-os-release` (shipped in the base, re-run by each derived image so student/staff report their own identity). Fedora's version stays visible via Silverblue's untouched `VERSION_ID`. The JSON lives under `svk-os/` (svk's own metadata; **not** the ublue path) and nothing in the update path reads it.
- **Signing** stays **bespoke and keyed** (do not switch to keyless): every image is cosign-signed (`COSIGN_PRIVATE_KEY` repo secret; cosign **v2.5.3** pinned), `cosign.pub` is baked into every image, and machines enforce it via `/etc/containers/policy.json` + `registries.d` (the `sha256-<digest>.sig` attachment scheme). A keyless signature would be invisible to this key-based policy and make the fleet reject updates — the #1 project risk.
- **ISOs**: built with **Titanoboa** (Anaconda), which pre-bakes the per-flavor flatpak set for offline first boot, then `bootc switch`es the origin to the signed registry ref for auto-updates. This replaced the old plain `bootc-image-builder` ISO path. Secure Boot key enrollment is intentionally skipped (no custom kmods on the raw-Silverblue base).
- **Server provisioning is different**: no ISO/`bootc switch` — compile `server.bu` (Butane) with `secrets/` inlined via `--files-dir .` (`just server-ign`), then install via Ignition/`coreos-installer`.
- **Rebuild scope discipline**: keep build scripts idempotent, avoid build-time network dependencies that aren't the registry itself, and remember flatpaks are an **ISO-install** artifact now (baked by Titanoboa), not an image or first-boot artifact.

See `README.md` for the operational overview and `TODO.md` for the one-time human setup checklist. The `archived/README.md` still documents the runtime networking / Tailscale / mirror / DNS design (only its *build* instructions are superseded).
