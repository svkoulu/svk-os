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
  └── svk-base              # Tailscale, mDNS, admin SSH, CLI tools, desktop defaults,
      │                       power switching, print stack, certs, fwupd, ghcr mirror, cosign
        ├── svk-student     # locked kiosk: autologin (opilas) + skel reset + dconf/polkit lockdown
        └── svk-staff       # normal desktop, --user flatpaks

ghcr.io/ublue-os/ucore:stable
  └── svk-server            # pull-through registry cache + hostname dispenser (independent)
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
cosign.pub                                  # your image-signing public key (committed)
secrets/                                    # server-install secrets (gitignored; see its README)
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
| `<<GHCR_NAMESPACE>>` | GitHub user/org owning the images — **set to `svkoulu`** | Containerfiles, workflows, `policy.json`, `registries.d`, `server.bu` |
| `<<REGISTRY_CACHE_HOST>>` | Cache server host — **set to `svk-server.local`** (mDNS, so LAN-only students resolve it too) | `files/base/.../010-ghcr-mirror.conf`, hostname-claim script |
| `<<ADMIN_SSH_PUBLIC_KEY>>` | Admin operator key — **filled**, baked into every device + `server.bu` | `files/base/etc/ssh/authorized_keys.d/admin`, `server.bu` |
| `<<ADD ... HERE>>` | Optional package/flatpak/font lists | `build.*.sh` |

Two **server-install secrets** are no longer inline placeholders — they're
injected from `secrets/` at compile time (`butane --files-dir .`) so they never
touch git. Create `secrets/id_ed25519` (the server's outbound SSH private key)
and `secrets/tailscale-authkey` (its one-off pre-auth key) — see
[`secrets/README.md`](secrets/README.md).

The mirror `location` and the hostname-claim `DISPENSER_HOST` both point at the
**same** server, `svk-server.local`. For the mirror use `svk-server.local:5000`;
for the dispenser the script already appends the port. `.local` (mDNS) rather
than the bare Tailscale name is deliberate — see [Remote access & local
networking](#remote-access--local-networking).

### 2. cosign setup (image signing)

Install `cosign` to `~/.local/bin` (make sure it's on your `PATH`):

```bash
curl -fsSL -o ~/.local/bin/cosign \
  https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
chmod +x ~/.local/bin/cosign
```

Generate a keypair locally — do **not** commit the private key:

```bash
cosign generate-key-pair
# Press ENTER at the password prompt for an empty password (simplest for CI),
# or set one and add it as the COSIGN_PASSWORD secret below.
```

- Commit the generated **`cosign.pub`** over the placeholder file at the repo root.
- Add the contents of **`cosign.key`** as the `COSIGN_PRIVATE_KEY` repo secret.
- `.gitignore` already blocks `cosign.key` from being committed.

`cosign.pub` is baked into every image at `/etc/pki/containers/svk-cosign.pub`
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

- Podman tries the **local cache first** (`svk-server.local:5000`), so 19
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

## Curated Flathub mirror

Same idea as the ghcr.io cache, one layer up: `svk-flathub-sync.py` runs daily
on the server (`svk-flathub-sync.timer`) and mirrors a **curated subset** of
Flathub — not the whole catalog (impractical size, and staff self-serve still
needs vetting) — into a local OSTree repo, served over HTTP by
`flathub-mirror-serve.container` (nginx) on `:8080`.

**Curation** (all must pass, from Flathub's own `appstream2/x86_64` branch):
FOSS license only, Flathub verified-developer flag
(`flathub::verification::verified` in the appstream custom metadata), no
broad sandbox permissions (`filesystem=host`, `socket=session-bus`/`system-bus`,
`device=all` — checked straight from each candidate ref's own `/metadata` file
via a partial `ostree pull --subpath`), and a clean OARS content rating (no
`violence-*`/`sex-*` category above `none`). Two admin-editable overrides on the
data volume — `/var/lib/svk/flathub-allowlist` and `-blocklist` (seeded from
`.example` files in `files/server/usr/share/svk/`, same pattern as
`hostname-pool.example`) — force-include or force-exclude specific app ids;
blocklist wins on conflict, and the sync script warns loudly if an id is on both.

**Trust**: the mirror re-serves Flathub's own commits (and their original
signatures) verbatim, so both the server's local OSTree repo and the client's
flatpak remote trust **Flathub's own signing key**, extracted fresh from their
published `flathub.flatpakrepo` at sync/first-boot time rather than hand-copied
into this repo (a future key rotation is picked up automatically instead of
silently breaking).

**Client side**: `svk-flatpak-preinstall.sh` (base, every machine) adds the
mirror as a second flatpak remote at **higher priority** (`--prio=2`) than the
real `flathub` remote. Any ref the mirror doesn't have falls through to real
Flathub automatically — this is a speed-up, never a restriction. Staff can
browse the curated catalog in GNOME Software; students stay locked to the
fixed `/etc/svk/flatpaks.list` set regardless (their existing
`org/gnome/software allow-updates=false` dconf lock already blocks
install/update from Software).

---

## DNS: AdGuard Home

`adguard-home.container` (Podman quadlet on the server) is the fleet's caching
resolver + blocklist filter + per-client config, all in one process. Config is
pre-seeded (`svk-adguard-seed.service` → `adguardhome.yaml.example`) so it
starts already-configured — no install-wizard interaction. **Log into
`http://svk-server.local:3000` and set a real admin password on first boot**
(the seeded config ships `users: []`, i.e. an open dashboard, since campus
network + Tailscale already gate who can reach it).

Blocklists are **self-hosted primary** — AdGuard Home downloads and applies
them itself, so filtering keeps working on campus even if some cloud API is
having a bad day. Client resolver config (`resolved.conf.d`, per image) then
decides what happens off-campus:

| Image | `resolved.conf.d` | Behavior |
|---|---|---|
| student | `DNS=svk-server.local` only, `DNSOverTLS=no` | Fail-closed — correct for a kiosk that never leaves campus. |
| staff | `DNS=svk-server.local <NextDNS DoT endpoint>`, `DNSOverTLS=opportunistic` | Local cache + self-hosted lists on-LAN; automatic fallback to NextDNS once off-site. |

Fill in `<<NEXTDNS_PROFILE_ID>>` in `files/staff/etc/systemd/resolved.conf.d/20-svk-dns.conf`
(my.nextdns.io → Setup → Router/Other → DNS-over-TLS gives you the profile id
that goes into both `dns1.nextdns.io`/`dns2.nextdns.io` hostnames there).

Per-client (student vs. staff) filtering differences live in AdGuard Home's own
`clients.persistent` list (`adguardhome.yaml.example`) — currently placeholder
CIDRs, since the real DHCP scopes don't exist yet; see `TODO.md`.

---

## Student Wi-Fi lockdown

Exactly **one** Wi-Fi connection is baked into
`files/student/etc/NetworkManager/system-connections/svk-student-wifi.nmconnection`
— the school's SSID, autoconnect, root-owned. `49-school-lockdown.rules`
denies `opilas` all `NetworkManager.settings.*` actions (so no second profile
can ever be added) plus the Wi-Fi enable/disable and network-control actions
(so the Quick Settings toggle / "Disconnect" no-ops instead of dropping the
one connection that exists).

The real `.nmconnection` file holds the school's actual Wi-Fi password, so
it's **gitignored** like everything under `secrets/` — only the `.example`
template is tracked. Copy it and fill in `<<STUDENT_WIFI_SSID>>` /
`<<STUDENT_WIFI_PSK>>` before building `svk-student` (see `TODO.md`).

**Open hardware question**: rfkill / "airplane mode" sometimes bypasses polkit
entirely via udev `uaccess` seat tagging — verify on real student hardware
once the first laptop is provisioned (see `TODO.md` §11-style items).

---

## uBlock Origin managed policy

Firefox reads exactly **one** `policies.json` (no merging like
`flatpaks.list.d`), so `files/student` and `files/staff` each ship a **full**
override of `files/base`'s policy — same pattern as `tailscale.conf` (base
ships a generic default that's never deployed standalone, since `svk-base`
itself never boots). The `3rdparty.Extensions["uBlock0@raymondhill.net"]` key
configures uBO's managed storage (`toOverwrite.filterLists`, `userSettings`) —
schema and filter-list tokens confirmed against uBO's own wiki and
`assets.json`, not the (older/stale) example on Mozilla's policy-templates page.

Students get **every** uBO list category, including cosmetic filtering
(`ignoreGenericCosmeticFilters=false`, explicit) and the Social widgets list
(`adguard-social`, `fanboy-social`, `fanboy-thirdparty_social`). Staff get
every category **except** Social.

---

## Provisioning machines onto an image

Install once from an ISO (see [ISOs](#building-installer-isos)) or any bootc
base, then rebase onto the target image:

```bash
# student kiosk
sudo bootc switch ghcr.io/svkoulu/svk-student:latest

# staff desktop
sudo bootc switch ghcr.io/svkoulu/svk-staff:latest

# server (usually done by server.bu at install; manual form:)
sudo bootc switch ghcr.io/svkoulu/svk-server:latest
```

Thereafter the machine auto-updates from the same ref. Pin to a dated tag
(`:stable-YYYYMMDD`) instead of `:latest` if you want to stage/roll back.

### Tailscale enrollment

Images **install** Tailscale but bake **no** auth key — it rides a USB and is
read once at first boot. Each image carries an explicit
`/etc/svk/tailscale.conf` with its tag and an enrol flag:

| Image | `TAILSCALE_TAG` | `TAILSCALE_ENROLL` |
|---|---|---|
| staff | `tag:svk-staff` | `yes` |
| student | `tag:svk-student` | `no` (off the tailnet; tag kept only for hostnames) |
| server | `tag:svk-admin` | `no` (enrols via Ignition instead) |

**Desktops** enrol automatically via `svk-tailscale-enroll.service` (in the base
image, enabled everywhere). On first boot it:

1. reads `/etc/svk/tailscale.conf`; if `TAILSCALE_ENROLL=no` (students), it stops.
2. mounts the **provisioning USB** — a filesystem **labelled `SVK-PROV`** holding
   a plain-text file **`tailscale-authkey`** — read-only.
3. runs `tailscale up --authkey <that key> --advertise-tags $TAILSCALE_TAG`.

No USB / no key ⇒ it logs and exits without blocking the boot; you can always
`tailscale up` by hand later. A stamp (`/var/lib/svk/.tailscale-enrolled`) makes
it one-shot, but a *failed* attempt retries on the next boot.

Because one USB enrols many staff laptops, its key must be a **reusable**,
`tag:svk-staff` pre-auth key (short expiry; revoke it after provisioning). The
**server** does not use this flow — `server.bu` writes its own one-off key via
Ignition.

**Can one USB install both staff and student machines?** The *auth-key* USB
(`SVK-PROV`), **yes** — students ignore it (`TAILSCALE_ENROLL=no`) and staff
consume it, so the same stick is safe for both. The *installer* media is
different, though: `svk-student` and `svk-staff` are separate ISOs, so each
device type boots from its own installer. (You can put the `SVK-PROV` data on a
second partition of the installer stick, but the ISO itself is still per-image.)

### Hostname provisioning

All machines roll off one image, so they'd share a hostname and collide on the
tailnet. This repo solves it with a tiny **hostname dispenser** on the server:

- Server: a socket-activated dispenser (`hostname-dispenser.socket` →
  `hostname-dispenser.sh`) hands out one name per machine from a **pool**. It's
  idempotent (same machine-id → same name) and keeps state on the data volume.
  The pool lives at `/var/lib/svk/hostname-pool` (auto-seeded from
  `files/server/usr/share/svk/hostname-pool.example`); **defining the real pool
  is a one-time admin task — see [`TODO.md`](TODO.md) §7.**
- Client: a first-boot oneshot (`svk-claim-hostname.service`) asks the
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

## Remote access & local networking

The fleet is bigger than a free Tailscale tailnet (~50 devices) once you count
the ~19+ student laptops, so the network is split into **two planes**:

- **LAN plane — mDNS / Avahi (`.local`), every machine including students.**
  Each box advertises `<hostname>.local` (Avahi) and resolves others' `.local`
  names (nss-mdns), both wired up in `build.base.sh` / `build.server.sh`. This is
  how untagged student machines reach the cache and dispenser
  (`svk-server.local`) and how the server reaches *them* — no tailnet needed.
- **Tailnet plane — Tailscale MagicDNS, main devices only.** Server, staff, and
  admin laptops. Students are deliberately **not** enrolled
  (`build.student.sh` disables `tailscaled`); that's what keeps us under the cap.

### The `admin` operator account (all devices)

Every device has a dedicated **`admin`** user (uid 980, system-range so it never
shows on the greeter), key-only, with passwordless sudo:

| Piece | Where |
|---|---|
| Authorized keys (admin operator + `svk-server`) | `files/base/etc/ssh/authorized_keys.d/admin` |
| SSH hardening — key-only, no root, `AllowGroups wheel`, modern crypto, no forwarding | `files/base/etc/ssh/sshd_config.d/10-svk-hardening.conf` |
| Passwordless sudo | `files/base/etc/sudoers.d/10-svk-admin` |
| Account + sshd/avahi enablement | `build.base.sh` |
| Home dir (created at boot; `/var/home` isn't in the image) | `files/base/etc/tmpfiles.d/svk-admin.conf` |

Only `admin` (group `wheel`) may SSH in — the `opilas` kiosk user and staff log
in at the console, never over SSH. The server gets the same hardening via
`server.bu`, **except** it allows TCP forwarding (it's the jump host below).

### The jump-host flow

Admin can't reach students directly (not on the tailnet), so the **server is the
bridge** between the tailnet and the LAN-only fleet:

```
admin laptop ──Tailscale SSH──▶ svk-server ──LAN SSH (admin@ , key)──▶ svk-student-NN.local
 (tag:svk-admin)                (tag:svk-server)                        (untagged, .local)
```

- **Hop 1** (admin → server) uses **Tailscale SSH** — authenticated by the ACL,
  no key needed. `ssh admin@svk-server.local` also works on the LAN (break-glass,
  via the admin operator key) if Tailscale is down.
- **Hop 2** (server → device) uses a **real SSH key**: the server's private key
  (`secrets/id_ed25519`, injected into `server.bu`), whose public half is in
  every device's `authorized_keys.d/admin`. One-liner from your laptop:
  `ssh -J admin@svk-server admin@svk-student-03.local` (the `-J` is why the
  server allows TCP forwarding while the leaf devices don't).
- The server already **knows every device name** it handed out —
  `/var/lib/svk/hostname-assignments` — or use `avahi-browse -rt _ssh._tcp`.

### Tailscale tags & ACL (define these in the admin console)

| Tag | Applies to |
|---|---|
| `tag:svk-admin` | IT operator laptops (source of admin access) |
| `tag:svk-server` | the cache / dispenser / jump-host server |
| `tag:svk-staff` | staff desktops (on the tailnet for remote support) |
| ~~`tag:svk-student`~~ | not enrolled — LAN-only (keep the tag *file* for the hostname prefix) |

```jsonc
{
  "tagOwners": {
    "tag:svk-admin":  ["autogroup:admin"],
    "tag:svk-server": ["autogroup:admin"],
    "tag:svk-staff":  ["autogroup:admin"]
  },
  "ssh": [
    { "action": "accept",
      "src": ["tag:svk-admin"],
      "dst": ["tag:svk-server", "tag:svk-staff"],
      "users": ["admin"] }
  ],
  "acls": [
    { "action": "accept", "src": ["tag:svk-admin"], "dst": ["*:*"] },
    { "action": "accept", "src": ["tag:svk-staff"], "dst": ["tag:svk-server:22,5000,8765"] }
  ]
}
```

---

## Building installer ISOs

`bootc switch` needs an already-running bootc system. To provision *bare metal*,
build an installer ISO from the Actions tab → **iso** → *Run workflow* (pick
`both`, `svk-student`, or `svk-staff`). It runs
[`bootc-image-builder`](https://github.com/osbuild/bootc-image-builder) and
uploads the `.iso` as a workflow artifact.

## uCore / Ignition caveat (server only)

The server uses a **different provisioning model** from the desktops. uCore is
Fedora CoreOS-based and provisions with **Ignition**, authored as **Butane**
(`server.bu`) — *not* from an installer ISO the way the desktops do. Compile and
install:

```bash
butane --pretty --strict --files-dir . server.bu > server.ign   # --files-dir pulls in secrets/
# boot the CoreOS/uCore installer, then:
coreos-installer install /dev/sda --ignition-file server.ign
```

`server.bu` creates the admin user, mounts the cache volume, enrolls Tailscale
(`tag:svk-admin`), and rebases onto `svk-server`. The compiled `server.ign`
holds the two `secrets/` values (the Tailscale key and the server's SSH private
key) in cleartext — keep it out of git (`.gitignore` covers `*.ign`).

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
`svk-base` from the registry:

```bash
podman build -f Containerfile.base   -t svk-base   .
podman build -f Containerfile.staff  -t svk-staff  .   # after base is pushed
podman build -f Containerfile.student -t svk-student .  # after base is pushed
podman build -f Containerfile.server -t svk-server .   # independent
```

(For a fully local student/staff build without pushing base first, temporarily
point their `FROM` at the local `svk-base` tag.)
