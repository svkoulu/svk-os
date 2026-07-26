# svk — school bootc image factory

## Purpose

Builds and signs **two bootc OCI images** for a small school IT fleet, publishes them to GHCR (`ghcr.io/svkoulu/...`). Machines are provisioned once from an installer ISO, then track their image via automatic `bootc` updates. Because these are custom images, the base is pinned by digest and does **not** inherit upstream updates automatically — a weekly CI rebuild (+ Renovate digest bumps) is what pulls in new kernels/security fixes. A silently broken pipeline means the fleet silently stops getting updates; that risk drives most of the design (`bootc container lint --fatal-warnings` as final layer, `fail-fast: false`, notify-on-failure).

## Image hierarchy

```
quay.io/fedora-ostree-desktops/silverblue   (raw Fedora Silverblue, pinned by DIGEST)
  └── svk-os         # THE desktop image — every lab machine AND staff laptop.
                     # Tailscale, mDNS, admin SSH, CLI tools, desktop defaults, power
                     # switching, certs, fwupd, ghcr mirror, cosign policy, plus the
                     # kiosk lockdown (dconf `kiosk` db, polkit, home reset).

ghcr.io/ublue-os/ucore:stable
  └── svk-server     # pull-through registry cache + hostname dispenser + curated Flathub
                     # mirror + AdGuard Home DNS (independent, provisioned via Ignition/Butane, not bootc switch)
```

**One image, no build-time flavors** (2026-07-27, `tasks/done/…-single-image-collapse.md`). `svk-base`/`svk-student`/`svk-staff` collapsed into `svk-os`. The rule that makes it safe: **the lockdown is scoped to the account, and the installer decides which accounts exist** — a lab machine gets `opilas` + `admin`, a staff laptop gets `staff` + `admin`. Everything kiosk-shaped gates on the `opilas` account existing (polkit `subject.user == "opilas"`, `ExecCondition=getent passwd opilas`), so it ships everywhere and is inert where that account was never created. Two consequences to keep in mind when changing things:

- **Never make kiosk behaviour machine-wide.** `/etc/dconf/profile/user` applies to every account, which is why the lockdown lives in a separate `kiosk` dconf db selected per-account via `DCONF_PROFILE` in `environment.d`. Same reasoning for GDM autologin (kickstart, not image) and the two kiosk units (`ExecCondition`).
- **The boundary is "this account cannot do X", not "this machine cannot".** App restrictions are group ownership + mode `0750` (`wheel` = the five admin apps, `svk-staff` = gnome-software), with per-account NoDisplay stubs prepended to `XDG_DATA_DIRS` to hide the icons. That makes the staff account's password load-bearing.
- **The id map is fixed fleet-wide**: `admin` 1000 (sysusers, first boot), `staff` 1001, `opilas` 1002 (both pinned uid *and* gid by their kickstart, which runs before sysusers and would otherwise take 1000). `admin` is above `UID_MIN`, so it is hidden from the greeter **explicitly** — `SystemAccount=true` written to `/var/lib/AccountsService/users/admin` by `files/os/etc/tmpfiles.d/svk-admin.conf`. That file and the sysusers uid are a matched pair; changing one alone puts admin back in the login screen. Fixed ids are also asserted free at build time (`build/30-users.sh`, `build/40-desktop.sh`) because a collision makes sysusers fall back silently.

Rebuilt (2026-07) the **modular way**: raw Silverblue + svk's own config, **not** `FROM ghcr.io/ublue-os/bluefin`. Raw `Containerfile`s (ublue `image-template` lineage), not BlueBuild — this is what lets a single workflow build both the Silverblue desktop and the uCore server. See `tasks/todo/…-modular-base-rebuild-*` for the rebuild rationale and decisions.

The desktop **apps** (Firefox, LibreOffice, VLC, GIMP, Inkscape, video tools) are **Flatpaks baked into the installer ISO** by Titanoboa — not installed at build time, and not at first boot. First boot is fully offline; the apps live in system scope (`/var/lib/flatpak`), so a student home-reset never loses them. Ongoing flatpak updates come from the server's LAN Flathub mirror. Teachers can add more at runtime — a narrow polkit grant lets the `svk-staff` group do **system-scope** flatpak installs (user-scope would land somewhere `opilas` can't see), which is also why `opilas` gets a denylist rather than an allowlist.

## Directory structure

```
Containerfile.{os,server}                    # one manifest per image
build/                                       # svk-os's build scripts, run in order:
  00-image-info.sh                           #   branding -> stamps os-release + svk-os/image-info.json (via the shared stamper)
  10-packages.sh                             #   dnf5 removals (RPM Firefox, gnome-tour, malcontent-control) + installs
  20-services.sh                             #   systemctl enable (sshd, avahi, tailscale, power, hostname, kiosk units)
  30-users.sh                                #   admin account (sysusers.d) + sudoers + ssh perms
  40-desktop.sh                              #   dconf dbs, the per-account app matrix, hidden-launcher sets, CA trust
  clean-stage.sh / copr-helpers.sh           #   build-artifact cleanup / COPR helpers
build.server.sh                              # the server image's build script
files/{os,server}/                           # static trees COPY'd to image "/"
flatpaks/common.list                         # the flatpak set baked into the ISO (+ a never-add list)
iso/                                         # Titanoboa ISO pipeline (build-iso.sh, installer/)
custom/                                      # ujust recipes shipped into the image
server.bu                                    # Butane for the uCore server's first install
cosign.{pub,key}                             # image-signing keypair (.key gitignored)
secrets/                                     # server-install secrets (gitignored)
archived/                                    # the previous FROM-bluefin implementation, for reference
Justfile                                     # local build + setup commands (CI does NOT use it)
.github/actions/build-image/                 # shared build+sign+push composite action
.github/workflows/build.yml                  # router: picks channel(s) per event (git tag/main/cron/dispatch)
.github/workflows/build-images.yml           # reusable: builds both images for one channel from one ref
.github/workflows/iso.yml                    # the installer ISO (Titanoboa) — one ISO, both roles
```

`Containerfile.os` is **multi-stage**: a `scratch` `ctx` stage gathers `build/` + `custom/`, then the final stage is Silverblue-pinned-by-digest; build logic runs via `RUN --mount=type=bind,from=ctx …` calling each `build/NN-*.sh`, then `clean-stage.sh`, then `bootc container lint --fatal-warnings`. Keep install/config logic in the numbered `build/` scripts, not in the Containerfile.

## Build strategy

- **No layering.** The two images are independent — `svk-os` is raw Silverblue, `svk-server` is uCore — so there is no build order and no `BASE_IMAGE` plumbing anywhere. Use the Justfile:
  ```bash
  just build-os                   # the desktop image
  just build-server               # independent (uCore)
  just build-all                  # both
  ```
- **Packages use `dnf5`**, not `rpm-ostree install` (`dnf5 config-manager setopt keepcache=1 install_weak_deps=0`; `dnf5 install -y`), with `--mount=type=cache` for the dnf cache. On a raw Silverblue base most of the old idempotency guards are unnecessary (the packages aren't already present) — keep a guard only where a package might already ship. To *remove* a Silverblue default, add it to the removal loop at the top of `10-packages.sh` (RPM Firefox so only the Flatpak ships, plus `gnome-tour` / `malcontent-control`; the malcontent **library** stays, held in reserve for per-user app filtering).
- **CI**: `.github/workflows/build.yml` is a thin router — its `setup` job decides which channel(s) to build per event (git tag → stable, push to main → testing, weekly cron → **stable only**, dispatch → choice) and computes the date + stable ref, then calls the reusable `.github/workflows/build-images.yml` once per channel. That workflow is a flat 2-entry matrix (`svk-os`, `svk-server`) over the shared `build-image` composite action. `svk-os` ends in `bootc container lint --fatal-warnings`; server uses plain `bootc container lint` (a base we don't control). `fail-fast: false` so one image's failure doesn't hide the other's. The cron builds stable only because testing already rebuilds on every push to main.
- **Versioning / channels** (ublue-style): two channels, each a rolling tag + immutable dated pins.
  - **stable** (from **git tags**): `:stable` (rolling, all lines), `:stable-<N>` (rolling within release line N), `:stable-<N>-<DATE>` (pinned). **The fleet tracks `:stable`** — or `:stable-<N>` to pin a line.
  - **testing** (from **main**): `:testing`, `:latest` (alias), `:testing-<DATE>` (pinned). Dev/test.
  - The **weekly cron builds stable only**, **rebuilt from the latest git tag** (security only — no unreleased code reaches the fleet). New features reach stable only when you cut a tag. testing is not on the cron: every push to main already rebuilds it.
  - One version string — `stable-<N>-<DATE>` or `testing-<DATE>` (e.g. `stable-1-20260718`) — flows into the image tag, os-release `IMAGE_VERSION`, the `org.opencontainers.image.version` label, `/usr/share/svk-os/image-info.json`, and the ISO filename. `channel`/`major`/`date` are computed once in `setup` and passed down so both images agree; the composite action assembles the tags. os-release + the JSON are stamped by `files/os/usr/libexec/svk/stamp-os-release`, which also ships in the image at `/usr/libexec/svk/`. Fedora's version stays visible via Silverblue's untouched `VERSION_ID`. The JSON lives under `svk-os/` (svk's own metadata; **not** the ublue path) and nothing in the update path reads it.
- **Signing** stays **bespoke and keyed** (do not switch to keyless): every image is cosign-signed (`COSIGN_PRIVATE_KEY` repo secret; cosign **v2.5.3** pinned), `cosign.pub` is baked into every image, and machines enforce it via `/etc/containers/policy.json` + `registries.d` (the `sha256-<digest>.sig` attachment scheme). A keyless signature would be invisible to this key-based policy and make the fleet reject updates — the #1 project risk.
- **ISOs**: **one ISO for the whole fleet**, built with **Titanoboa** (Anaconda). It pre-bakes the flatpak set for offline first boot, then `bootc switch`es the origin to the signed registry ref for auto-updates. It carries **both role kickstarts** (`svk-lab.ks` / `svk-staff.ks`) as two automated GRUB entries — that menu choice is the only thing that distinguishes a lab machine from a staff laptop, and it runs under `inst.cmdline` so a kickstart gap aborts visibly instead of parking on a prompt. Secure Boot key enrollment is intentionally skipped (no custom kmods on the raw-Silverblue base).
- **Server provisioning is different**: no ISO/`bootc switch` — compile `server.bu` (Butane) with `secrets/` inlined via `--files-dir .` (`just server-ign`), then install via Ignition/`coreos-installer`.
- **Rebuild scope discipline**: keep build scripts idempotent, avoid build-time network dependencies that aren't the registry itself, and remember flatpaks are an **ISO-install** artifact (baked by Titanoboa), not an image or first-boot artifact.
- **Role config belongs to the installer, not the image.** Anything that differs between a lab machine and a staff laptop — the accounts, GDM autologin, `DCONF_PROFILE`, the hidden-launcher set — is written by the kickstart's role `%post` (`iso/installer/build.sh`). Anything that differs per *site* — Tailscale enrolment, DNS profile, Wi-Fi, the staff password — is the USB provisioning config's job (`tasks/todo/20260719-0110-usb-provisioning-config.md`), and ships as a fleet-wide default in the meantime. If you find yourself adding a build-time conditional to make one machine behave differently, it belongs in one of those two places instead.

See `README.md` for the operational overview and `TODO.md` for the one-time human setup checklist. The `archived/README.md` still documents the runtime networking / Tailscale / mirror / DNS design (only its *build* instructions are superseded).
