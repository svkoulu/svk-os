You are scaffolding a Git repository that acts as an image factory for a small school
IT fleet. It builds **four signed bootc OCI images** with GitHub Actions and publishes them
to GHCR. Machines are provisioned once and thereafter `bootc switch` / auto-update from these
images. Keep everything **lean and well-commented**. Do not add speculative features,
frameworks, or abstractions. Prefer the smallest thing that works. This is maintained at
roughly 6 hours a month by one person, so clarity and low operational surface matter more
than cleverness.

## Context you need

- Model: Universal Blue / bootc. Images are built from a `Containerfile` (`FROM` an upstream
  bootc base), published to GHCR, and consumed with `bootc switch`. Custom images do **not**
  inherit upstream updates automatically, so the base is pinned at build time and the pipeline
  must rebuild on a schedule to pull in new kernels and security fixes.
- Fleet: ~19 student laptops (locked kiosk), a handful of staff laptops, and one server that
  runs a **pull-through registry cache** so 19 machines don't each pull multi-GB layers over an
  unstable school network.
- Per-user software variation is handled by **Flatpak `--user` installs**, never by baking
  per-person packages into images. We'll pre-install some flatpaks and system packages into the
  images, just leave a placeholder comment where I can add those later.

## Image hierarchy (use these exact bases)

```
ghcr.io/ublue-os/bluefin:stable
  └── school-base
        ├── school-student
        └── school-staff
ghcr.io/ublue-os/ucore:stable
  └── school-server        (independent branch; NOT built on school-base)
```

Use raw `Containerfile`s (ublue `image-template` lineage), not BlueBuild, so the same workflow
uniformly builds both the Bluefin-based desktop images and the uCore-based server. (Mention in
the README that BlueBuild is a cleaner alternative for the three desktop images if we ever drop
the server from this repo.)

The server will be running by the time other machies will be installed. The server will need
a software that provisions machines their hostnames based on a hardcoded list/pool of options.
The pool will be defined later, so you can create one for now. Either this, or you need to provide
an alternative, better solution for provisioning unique hostnames that resolve inside the tailscale
network.

## Per-image requirements

**school-base** (`FROM ghcr.io/ublue-os/bluefin:stable`)
- Tailscale present (installed only; **no auth keys baked in** — see placeholders).
  Need a way to activate them, either baked in or on install by putting the key in the USB.
- Print stack + any school CA certs, fonts.
- `fwupd` present (matches existing HP firmware workflow).
- A `registries.conf.d` drop-in mirroring `ghcr.io` through the local cache
  (`<<REGISTRY_CACHE_HOST>>`), configured as a **non-exclusive mirror that falls back to
  ghcr.io** if the cache is unreachable. This one drop-in covers both upstream layers and our
  own images, since ours also live on ghcr.io.
- cosign signing policy for our images.

**school-student** (`FROM school-base`)
- GDM autologin to a single **passwordless `student`** account.
- `/home/student` reset to `/etc/skel` on logout. Implement as a systemd unit + small script;
  this is the trickiest piece, so comment it clearly and leave a `# REVIEW:` marker. Provide a
  working first cut, do not stub it.
- dconf + polkit lockdown (`/etc/dconf/db/local.d/` with locks + `dconf update` at build;
  polkit rules under `/etc/polkit-1/rules.d/`).
- **System Flatpaks only.** Strip/disable Distrobox and Homebrew (Bluefin ships them).
- Tailscale ACL tag `tag:svk-student`.

**school-staff** (`FROM school-base`)
- Normal login, no kiosk lockdown, no skel reset.
- Flatpak `--user` installs permitted (`~/.local/share/flatpak` persists across updates).
- No Distrobox or Homebrew
- Tailscale ACL tag `tag:svk-staff`.

**school-server** (`FROM ghcr.io/ublue-os/ucore:stable`)
- Runs a **pull-through registry cache** for `ghcr.io`, as a Podman **quadlet**
  (`/etc/containers/systemd/*.container`). Use `registry:2` in proxy mode
  (`REGISTRY_PROXY_REMOTEURL=https://ghcr.io`) or Zot — pick one, keep it simple, put the cache
  storage on a data volume (target: 1TB NVMe).
- Do **not** give the server the ghcr.io→cache mirror drop-in (it must reach real ghcr.io).
- Cockpit is already in uCore; just ensure it's enabled. Tailscale tag `tag:svk-admin`.
- Add a README note: uCore uses CoreOS **Ignition/Butane** provisioning, a different model from
  the desktop images. Include a minimal Butane snippet for first install.

## GitHub Actions

- Triggers: weekly `schedule` (cron), `push` to main, and `workflow_dispatch`.
- Jobs / order:
  - `build-base` builds + pushes `school-base`.
  - `build-student` and `build-staff` **`needs: build-base`** (so they FROM the freshly pushed base).
  - `build-server` is independent (`needs: []`).
- Each job: `bootc container lint`, build with Podman, **cosign sign** the pushed image, push to
  `ghcr.io/<<GHCR_NAMESPACE>>/<image>:latest` plus a date tag `:stable-YYYYMMDD`.
- Signing uses a committed `cosign.pub` and a `COSIGN_PRIVATE_KEY` repo **secret**. Include
  setup instructions (`cosign generate-key-pair`), do not generate or commit real keys.
- Add a **separate** `iso.yml` (manual dispatch) that runs `bootc-image-builder` to produce
  installer ISOs for `school-student` and `school-staff`.
- **Fail loudly:** on any build failure, the workflow must surface it (job fails visibly; add a
  short note in the README on wiring a notification). A silently broken pipeline = fleet stops
  getting security updates unnoticed, which is the main risk in this whole design.

## Expected repo layout

```
.
├── Containerfile.base
├── Containerfile.student
├── Containerfile.staff
├── Containerfile.server
├── files/
│   ├── base/etc/...           # registries.conf.d drop-in, certs, cosign policy
│   ├── student/etc/...        # gdm autologin, dconf db + locks, polkit, skel-reset unit+script
│   ├── staff/etc/...
│   └── server/etc/containers/systemd/registry.container  # quadlet
├── server.bu         # Butane for uCore first install
├── .github/workflows/build.yml
├── .github/workflows/iso.yml
├── cosign.pub                 # placeholder / generated by me
└── README.md
```

Prefer a small shared `build.sh` per image over inlining long RUN chains, if it stays readable.

## Placeholders to leave for me (do not invent values)

- `<<GHCR_NAMESPACE>>` — GitHub user/org for the image path.
- `<<REGISTRY_CACHE_HOST>>` — hostname of the cache server (likely its Tailscale name).
- Tailscale enrollment — install only; leave a clear TODO for supplying a pre-auth key at
  provision time via secret/Ignition. **Never bake auth keys or any secret into an image.**
- cosign keypair — instructions only.

## Definition of done

- All four `Containerfile`s build locally with `podman build` (agent should dry-run the lint/build
  logic mentally and fix obvious breakage). You don't have podman available, I'll run those. Tell
  me what to do once you're done.
- `build.yml` builds all four in correct dependency order, signs, and pushes with both tags.
- `iso.yml` produces student/staff ISOs on dispatch.
- README documents: secrets to set, cosign setup, how to `bootc switch` a machine onto each
  image, how the cache mirror + fallback works, and the uCore/Ignition caveat.
- No secrets, no real keys, no hardcoded hostnames — only the marked placeholders.
