# svk — school bootc image factory

Builds and signs **four bootc OCI images** for a small school IT fleet and
publishes them to GHCR. Machines are provisioned once, then track these images
with `bootc switch` / automatic updates.

Because these are *custom* bootc images, they do **not** inherit upstream
updates automatically — the base is pinned at build time. The weekly CI rebuild
is what pulls in new kernels and security fixes. **If the pipeline silently
breaks, the fleet silently stops getting security updates.** That's the main
risk this repo is designed around; see [Fail loudly](#fail-loudly).

> **New to this repo?** Work through [`TODO.md`](TODO.md) — the checklist of
> values, secrets, and one-time actions a human must do to get from this
> scaffold to a running fleet.

## Image hierarchy

```
ghcr.io/ublue-os/bluefin:stable
  └── school-base              # Tailscale, print stack, certs, fwupd, ghcr mirror, cosign policy
        ├── school-student     # locked kiosk: autologin + skel reset + dconf/polkit lockdown
        └── school-staff       # normal desktop, --user flatpaks

ghcr.io/ublue-os/ucore:stable
  └── school-server            # pull-through registry cache + hostname dispenser (independent)
```

We use raw `Containerfile`s (the ublue `image-template` lineage) rather than
BlueBuild, so **one** workflow uniformly builds both the Bluefin desktops and
the uCore server. If the server ever leaves this repo, **BlueBuild is a cleaner
option for the three desktop images** — it replaces the Containerfiles +
build scripts with declarative recipe YAML. It just can't build the uCore
server as neatly, which is why we don't use it here.

## Repo layout

```
Containerfile.{base,student,staff,server}   # one manifest per image
build.{base,student,staff,server}.sh        # package installs / config per image
files/{base,student,staff,server}/          # static trees COPY'd to image "/"
server.bu                                   # Butane for the uCore server's first install
cosign.pub                                  # your image-signing public key (placeholder here)
.github/actions/build-image/                # shared build+sign+push composite action
.github/workflows/build.yml                 # weekly/push/dispatch: build all four
.github/workflows/iso.yml                   # manual: student/staff installer ISOs
```

---

## First-time setup

### 1. Fill in the placeholders

Nothing builds until every `<<...>>` marker is replaced. Find them with:

```bash
grep -rn '<<' . --include=Containerfile.\* --include=\*.sh --include=\*.yml \
                --include=\*.conf --include=\*.json --include=\*.yaml --include=\*.bu
```

| Placeholder | Meaning | Where |
|---|---|---|
| `<<GHCR_NAMESPACE>>` | GitHub user/org owning the images | Containerfiles, workflows, `policy.json`, `registries.d`, `server.bu` |
| `<<REGISTRY_CACHE_HOST>>` | Cache server host (its Tailscale name), e.g. `svk-server:5000` for the mirror | `files/base/.../010-ghcr-mirror.conf`, hostname-claim script |
| `<<ADMIN_SSH_PUBLIC_KEY>>` | Your SSH key for the server | `server.bu` |
| `<<TAILSCALE_AUTHKEY>>` | Server's one-off pre-auth key (Ignition only, never an image) | `server.bu` |
| `<<ADD ... HERE>>` | Optional package/flatpak/font lists | `build.*.sh` |

The mirror `location` and the hostname-claim `DISPENSER_HOST` both point at the
**same** server. For the mirror use `host:5000`; for the dispenser the script
already appends the port.

### 2. cosign setup (image signing)

Generate a keypair locally — do **not** commit the private key:

```bash
cosign generate-key-pair
# Press ENTER at the password prompt for an empty password (simplest for CI),
# or set one and add it as the COSIGN_PASSWORD secret below.
```

- Commit the generated **`cosign.pub`** over the placeholder file at the repo root.
- Add the contents of **`cosign.key`** as the `COSIGN_PRIVATE_KEY` repo secret.
- `.gitignore` already blocks `cosign.key` from being committed.

`cosign.pub` is baked into every image at `/etc/pki/containers/school-cosign.pub`
and referenced by `/etc/containers/policy.json`, so machines only accept images
signed with your key.

### 3. Repo secrets

| Secret | Required | Purpose |
|---|---|---|
| `COSIGN_PRIVATE_KEY` | yes | cosign private key (contents of `cosign.key`) |
| `COSIGN_PASSWORD` | only if your key has one | password for the cosign key |
| `GITHUB_TOKEN` | automatic | pushing to GHCR (no setup needed) |

The first time you publish, the GHCR packages are private; make them public (or
grant the fleet read access) so machines can pull. Settings → Packages.

---

## How the cache mirror + fallback works

Every desktop image ships `files/base/etc/containers/registries.conf.d/010-ghcr-mirror.conf`,
which registers the school server as a **non-exclusive mirror** for `ghcr.io`:

- Podman tries the **local cache first** (`<<REGISTRY_CACHE_HOST>>`), so 19
  laptops don't each drag multi-GB layers over the school's unstable network.
- If the cache is **unreachable** (server down, or a staff laptop off-site),
  Podman **falls back to `ghcr.io`** automatically. The machine stays bootable.
- One drop-in covers **both** upstream layers *and* our own images, because
  ours also live on `ghcr.io`.

The **server itself does not** ship this drop-in — it must reach the real
`ghcr.io` to populate the cache (`registry:2` in proxy mode, quadlet at
`files/server/etc/containers/systemd/registry.container`, storage on the 1TB
NVMe at `/var/mnt/registry-cache`).

---

## Provisioning machines onto an image

Install once from an ISO (see [ISOs](#building-installer-isos)) or any bootc
base, then rebase onto the target image:

```bash
# student kiosk
sudo bootc switch ghcr.io/<<GHCR_NAMESPACE>>/school-student:latest

# staff desktop
sudo bootc switch ghcr.io/<<GHCR_NAMESPACE>>/school-staff:latest

# server (usually done by server.bu at install; manual form:)
sudo bootc switch ghcr.io/<<GHCR_NAMESPACE>>/school-server:latest
```

Thereafter the machine auto-updates from the same ref. Pin to a dated tag
(`:stable-YYYYMMDD`) instead of `:latest` if you want to stage/roll back.

### Tailscale enrollment (TODO — no keys in images)

Images **install** Tailscale but bake **no** auth key. Each machine enrolls at
provision time. Supply a one-off pre-auth key then and run, using the tag baked
at `/etc/school/tailscale-tag` (`tag:svk-student` / `tag:svk-staff` / `tag:svk-admin`):

```bash
sudo tailscale up \
  --authkey "$AUTHKEY_FROM_USB_OR_IGNITION" \
  --advertise-tags "$(cat /etc/school/tailscale-tag)"
```

**TODO for the maintainer:** decide the key-delivery channel — a file on the
install USB, or (for the server) the Ignition `tailscale-authkey` file in
`server.bu`. **Never** commit a key or bake one into an image.

### Hostname provisioning

All machines roll off one image, so they'd share a hostname and collide on the
tailnet. This repo solves it with a tiny **hostname dispenser** on the server:

- Server: a socket-activated dispenser (`hostname-dispenser.socket` →
  `hostname-dispenser.sh`) hands out one name per machine from a **pool**. It's
  idempotent (same machine-id → same name) and keeps state on the data volume.
- The **pool is defined later** — edit `/var/lib/school/hostname-pool` on the
  server. A placeholder pool ships at
  `files/server/usr/share/school/hostname-pool.example` and is auto-seeded on
  first run.
- Client: a first-boot oneshot (`school-claim-hostname.service`) asks the
  dispenser for a name and sets it. If the server is unreachable it falls back
  to a deterministic `svk-<tag>-<machineid>` name, so **provisioning never
  blocks**.

**Simpler alternative (lower surface):** Tailscale MagicDNS already
deduplicates and gives every node a stable tailnet DNS name automatically. If
you don't care about *friendly* pool names, you can drop the dispenser entirely
and let Tailscale suffix duplicates (`svk-student`, `svk-student-1`, …). The
dispenser exists only to make those names curated and meaningful; it is not
required for machines to resolve on the tailnet.

---

## Building installer ISOs

`bootc switch` needs an already-running bootc system. To provision *bare metal*,
build an installer ISO from the Actions tab → **iso** → *Run workflow* (pick
`both`, `school-student`, or `school-staff`). It runs
[`bootc-image-builder`](https://github.com/osbuild/bootc-image-builder) and
uploads the `.iso` as a workflow artifact.

## uCore / Ignition caveat (server only)

The server uses a **different provisioning model** from the desktops. uCore is
Fedora CoreOS-based and provisions with **Ignition**, authored as **Butane**
(`server.bu`) — *not* from an installer ISO the way the desktops do. Compile and
install:

```bash
butane --pretty --strict server.bu > server.ign
# boot the CoreOS/uCore installer, then:
coreos-installer install /dev/sda --ignition-file server.ign
```

`server.bu` creates the admin user, mounts the cache volume, enrolls Tailscale
(`tag:svk-admin`), and rebases onto `school-server`. Keep `server.ign` out of git
(`.gitignore` covers `*.ign`); it may contain the Tailscale key.

---

## Fail loudly

A silently broken build = the fleet quietly stops getting security updates,
which is the worst-case failure here. Mitigations in place:

- `bootc container lint` runs as the final layer of every Containerfile, so a
  bad image fails the build instead of shipping.
- `fail-fast: false` on the matrix jobs so one image's failure doesn't mask the
  others.
- Failed jobs show red in the Actions tab and email the repo admins by default.

**Recommended: add an active failure notification** so nobody has to remember to
check. Append a final job to `build.yml` that runs `if: failure()` and pings a
chat webhook, e.g.:

```yaml
  notify-failure:
    needs: [build-base, build-derived, build-server]
    if: failure()
    runs-on: ubuntu-latest
    steps:
      - run: |
          curl -fsS -X POST "${{ secrets.ALERT_WEBHOOK }}" \
            -d '{"text":"svk image build FAILED — fleet is not getting updates"}'
```

Also enable GitHub's *Actions → notifications* for failed scheduled runs, since
scheduled failures are the easiest to miss.

---

## Building locally

You need `podman` (and `bootc` is included in the base images, so the in-build
lint just works). Build order matters only for the derived images, which pull
`school-base` from the registry:

```bash
podman build -f Containerfile.base   -t school-base   .
podman build -f Containerfile.staff  -t school-staff  .   # after base is pushed
podman build -f Containerfile.student -t school-student .  # after base is pushed
podman build -f Containerfile.server -t school-server .   # independent
```

(For a fully local student/staff build without pushing base first, temporarily
point their `FROM` at the local `school-base` tag.)
