# TODO — admin setup checklist

What a human still needs to do to get from this repo to a running fleet. Reflects
the **modular rebuild** (svk now builds `FROM` raw Fedora Silverblue + svk config,
not `FROM bluefin`; ISOs bake flatpaks offline via Titanoboa). Items marked
`[x]` are done in-repo; `[ ]` need a person. See `README.md` for the how-to.

## 0. Rebuild status (where the code is)

- [x] `svk-base` rebuilt on Silverblue; builds green (`bootc container lint
      --fatal-warnings`), verified locally.
- [x] `svk-student` / `svk-staff` adapted; build green, verified locally.
- [x] `svk-server` restored unchanged (uCore); CI verifies.
- [x] CI (`build.yml`) adapted; merged to `main`.
- [ ] **Confirm the first CI build on `main` is green** (Actions tab). Watch-item:
      the runner's podman must support `RUN --mount=type=bind,from=stage` +
      `type=cache` (ubuntu-24.04 / podman 4.9 expected fine).
- [x] **After the first green build, make the 4 GHCR packages public** (or grant
      the fleet read access): Settings → Packages. Pushing to `main` publishes the
      **testing** channel (`:testing` + `:latest` + `:testing-YYYYMMDD`); the fleet's
      **stable** channel (`:stable` + `:stable-N` + `:stable-N-YYYYMMDD`) appears only
      after you cut the first **git tag** (e.g. `git tag 1 && git push --tags`).
      Confirm `svk-base`, `svk-student`, `svk-staff`, `svk-server` show the tags.

## 1. Finish Phase 5 — ISOs (Titanoboa) — needs AC power

The ISO pipeline (`iso/`) is written but **NOT yet validated end-to-end**. See
`iso/README.md`. Note: upstream Titanoboa did a breaking rewrite (PR #138,
2026-05-19) that dropped its old Justfile/`HOOK_post_rootfs` interface and
Anaconda entirely — the pipeline was adapted to the new container-native
contract (a throwaway `iso/installer/` image now bakes Anaconda + the kickstart +
flatpaks + live-boot support, instead of Titanoboa injecting a hook).

- [ ] Run one ISO build (`just iso student local`) and fix any
      Anaconda/Titanoboa plumbing it surfaces.
- [x] Pin Titanoboa to a real tested commit in `iso/build-iso.sh` (was `@main`).
- [x] **Per-image branding + metadata** — done. Each image stamps its own os-release
      (`NAME`/`IMAGE_ID`/`IMAGE_VERSION`) **and** `/usr/share/svk-os/image-info.json`
      (channel/version/release-tag/base/fedora) via `/usr/libexec/svk/stamp-os-release`,
      so student/staff report their own identity + the channel build version, not
      `svk-base`.
- [ ] **LAN-mirror `flatpak update` wiring** (D7): baked flatpaks update from the
      server's curated Flathub mirror over the LAN. Client-side remote setup is
      still TODO — repurpose the GPG-key/`--prio` logic from the old
      `svk-flatpak-preinstall.sh` (kept in `archived/`).

## 2. cosign signing

- [x] `cosign generate-key-pair` (`just cosign-keygen`); real `cosign.pub` committed.
- [x] Confirm `cosign.key` contents are set as the `COSIGN_PRIVATE_KEY` repo secret
      (and `COSIGN_PASSWORD` if the key has one). Without it, CI build+push succeed
      but the sign step fails.

## 3. Fail-loudly notification (strongly recommended)

- [ ] Add a `notify-failure` job to `build.yml` (`if: failure()`) pinging a chat
      webhook via an `ALERT_WEBHOOK` secret. A silently broken build = the fleet
      stops getting security updates — the single most important safeguard.
- [ ] Enable GitHub Actions email/notification for failed **scheduled** runs.

## 4. Placeholders & secrets

- [ ] `<<STUDENT_WIFI_SSID>>` / `<<STUDENT_WIFI_PSK>>`: `just wifi-profile`, then
      fill the real (gitignored) `.nmconnection` before building `svk-student`.
- [ ] `secrets/id_ed25519` (server outbound SSH key) + `secrets/tailscale-authkey`
      (server pre-auth key): `just bootstrap-secrets` handles the SSH key; create
      the tailscale key by hand. See `secrets/README.md`.
- [x] `<<GHCR_NAMESPACE>>` → `svkoulu`; `<<REGISTRY_CACHE_HOST>>` →
      `svk-server.local`; `<<ADMIN_SSH_PUBLIC_KEY>>`; `<<NEXTDNS_PROFILE_ID>>` — set.
- [ ] Optional: school packages in `build/10-packages.sh` (`<<ADD ... HERE>>`),
      print stack, fonts (`files/base/usr/share/fonts/`), CA certs
      (`files/base/etc/pki/ca-trust/source/anchors/`).

## 5. Server first install (uCore / Ignition)

- [ ] `just server-ign` → `coreos-installer install /dev/sdX --ignition-file server.ign`.
- [ ] Provision the 1TB NVMe, mount at `/var/mnt/registry-cache`.
- [ ] Verify: registry cache (`registry.service` + a cached pull through
      `svk-server:5000`), Cockpit + Tailscale (`tag:svk-admin`), Flathub mirror
      (`svk-flathub-sync.service`; `journalctl -u svk-flathub-sync` for the curated
      count), AdGuard Home (`http://svk-server.local:3000` — **set a real admin
      password**; seeded config ships an open dashboard).

## 6. Tailscale, hostnames, data-volume lists

- [x] Tailscale ACL tags/policy + USB (`SVK-PROV`) enrol flow shipped.
- [ ] Prepare the `SVK-PROV` USB: filesystem label `SVK-PROV`, file
      `tailscale-authkey` = a **reusable** `tag:svk-staff` pre-auth key (short
      expiry; revoke after provisioning). Students ignore it.
- [x] Hostname pool defined (`/var/lib/svk/hostname-pool`).
- [ ] Flathub curation overrides (`/var/lib/svk/flathub-{allow,block}list`) — only
      if the automatic filters aren't enough; most schools won't need them.
- [ ] Real DHCP scopes → replace the placeholder CIDRs in AdGuard's
      `clients.persistent` so per-client (student/staff) filtering takes effect.

## 7. First fleet machine — smoke test (before rolling out all ~19)

Build a student ISO, install one laptop, and verify **on real hardware**:

- [ ] **Autologin** into `opilas` (sysusers-locked account — confirm GDM autologin
      works), **home reset** on logout, dconf/polkit **lockdown**.
- [ ] **Baked flatpaks present offline** (`flatpak list --system`: Firefox,
      LibreOffice, VLC, GIMP, VideoTrimmer, OpenShot, LosslessCut) and **survive a
      logout/home-reset** (they're system-scope, not in `/home/opilas`).
- [ ] **Flatpak updates pull from the LAN mirror** (once §1 wiring lands), not the
      internet.
- [ ] **Firefox policy + uBlock Origin** active (`about:policies`, uBO dashboard —
      Social list checked on student, unchecked on staff).
- [ ] **admin SSH** from the LAN; **image auto-updates** pull through the cache.
- [ ] **Which updater is active?** `systemctl list-timers` — this repo jitters both
      `uupd.timer` and `bootc-fetch-apply-updates.timer`; confirm the active one
      drives updates (move the `10-svk-randomize.conf` drop-in if not).
- [ ] **Student Wi-Fi lockdown**: can't add a second network; Wi-Fi toggle no-ops;
      test **rfkill/airplane mode** (can bypass polkit via udev `uaccess`).
- [ ] **DNS fail-closed on students** off the school AP (resolution fails rather
      than falling back to an unfiltered upstream).
- [ ] **Power switching**: `power-saver` on battery, `balanced` on AC
      (`powerprofilesctl get` after plug/unplug).
- [ ] Review the `# REVIEW:` marker in `files/student/usr/bin/reset-opilas-home.sh`
      (logout→reset→autologin timing).
