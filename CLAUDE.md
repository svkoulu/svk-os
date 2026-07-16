# svk — school bootc image factory

## Purpose

Builds and signs **four bootc OCI images** for a small school IT fleet, publishes them to GHCR (`ghcr.io/svkoulu/...`). Machines are provisioned once, then track their image via `bootc switch` + auto-update. Because these are custom images, they don't inherit upstream updates automatically — a weekly CI rebuild is what pulls in new kernels/security fixes. A silently broken pipeline means the fleet silently stops getting updates; that risk drives most of the design (`bootc container lint` as final layer, `fail-fast: false`, notify-on-failure).

## Image hierarchy

```
ghcr.io/ublue-os/bluefin:stable
  └── svk-base       # Tailscale, mDNS, admin SSH, CLI tools, power profiles, print stack, certs, fwupd, ghcr mirror, cosign
        ├── svk-student   # locked kiosk: autologin + skel reset + dconf/polkit lockdown
        └── svk-staff     # normal desktop, --user flatpaks

ghcr.io/ublue-os/ucore:stable
  └── svk-server     # pull-through registry cache + hostname dispenser (independent, provisioned via Ignition/Butane, not bootc switch)
```

Raw `Containerfile`s (ublue `image-template` lineage), not BlueBuild — this is the one thing that lets a single workflow build both the Bluefin desktops and the uCore server.

## Directory structure

```
Containerfile.{base,student,staff,server}   # one manifest per image
build.{base,student,staff,server}.sh        # package installs / config per image
files/{base,student,staff,server}/          # static trees COPY'd to image "/"
server.bu                                   # Butane for the uCore server's first install
cosign.{pub,key}                            # image-signing keypair (.key gitignored)
secrets/                                    # server-install secrets (gitignored)
.github/actions/build-image/                # shared build+sign+push composite action
.github/workflows/build.yml                 # weekly/push/dispatch: builds all four
.github/workflows/iso.yml                   # manual: student/staff installer ISOs
```

Each `Containerfile.X` should stay a thin, readable manifest: `FROM` → `COPY files/X/`→ `COPY + RUN build.X.sh` → `bootc container lint`. All package installs / systemd enables / config logic belong in `build.X.sh`, not the Containerfile.

## Build strategy

- **Layering**: `svk-base` is built and pushed first; `svk-student`/`svk-staff` pull it `FROM ghcr.io/svkoulu/svk-base`. `svk-server` is independent (uCore, not Bluefin).
- **Local build order**: base → (staff, student) after base is pushed; server anytime.
  ```bash
  podman build -f Containerfile.base    -t svk-base    .
  podman build -f Containerfile.staff   -t svk-staff   .
  podman build -f Containerfile.student -t svk-student .
  podman build -f Containerfile.server  -t svk-server  .
  ```
- **CI**: `.github/workflows/build.yml` runs the matrix weekly (cron), on push, and on manual dispatch; each job ends in `bootc container lint`; jobs use `fail-fast: false` so one image's failure doesn't hide the others' status.
- **Signing**: every image is cosign-signed (`COSIGN_PRIVATE_KEY` repo secret); `cosign.pub` is baked into every image and enforced via `/etc/containers/policy.json`, so machines only pull images signed with this repo's key.
- **Server provisioning is different**: no ISO/`bootc switch` — compile `server.bu` (Butane) with `secrets/` inlined via `--files-dir .`, then install via Ignition/`coreos-installer`.
- **Rebuild scope discipline**: keep `build.*.sh` idempotent (rpm-ostree errors on already-installed packages) and avoid build-time network dependencies that aren't the registry itself (e.g. Flatpaks install at first boot, not build time).

See `README.md` for the full operational runbook (networking, Tailscale enrollment, hostname dispenser, jump-host SSH flow, first-time setup).
