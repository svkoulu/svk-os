# TODO — admin setup checklist

Things a human must still do before / after this repo builds a working fleet.
The scaffolding is complete; these are the values, secrets, and one-time actions
that (correctly) can't live in git. See `README.md` for the how-to on each.

## 1. Fill in the placeholders (nothing builds until this is done)

Find them all: `grep -rn '<<' . --include=Containerfile.\* --include=\*.sh \
  --include=\*.yml --include=\*.conf --include=\*.json --include=\*.yaml --include=\*.bu`

- [ ] `<<GHCR_NAMESPACE>>` — GitHub user/org that owns the images. Replace in the
      Containerfiles, `build.yml`, `iso.yml`, `policy.json`, `registries.d/ghcr-school.yaml`,
      and `server.bu`.
- [ ] `<<REGISTRY_CACHE_HOST>>` — cache server host. Use `svk-server:5000` in the
      mirror drop-in (`files/base/.../010-ghcr-mirror.conf`); the hostname-claim
      script (`files/base/.../school-claim-hostname.sh`) wants just the host.
- [ ] `<<ADMIN_SSH_PUBLIC_KEY>>` — your SSH public key, in `server.bu`.
- [ ] `<<TAILSCALE_AUTHKEY>>` — server's one-off pre-auth key, in `server.bu`
      only (it goes into Ignition, never an image). Delete after first install.
- [ ] `<<ADD ... HERE>>` — optional system-package / flatpak / font lists in
      `build.base.sh`, `build.student.sh`, `build.staff.sh`.

## 2. cosign signing

- [ ] `cosign generate-key-pair` (press ENTER for an empty password = simplest).
- [ ] Commit the real `cosign.pub` over the placeholder at the repo root.
- [ ] Add `cosign.key`'s contents as the `COSIGN_PRIVATE_KEY` repo secret.
      (`.gitignore` already blocks committing `cosign.key`.)
- [ ] If you set a key password, add it as the `COSIGN_PASSWORD` repo secret.

## 3. GitHub / GHCR

- [ ] Push this repo to GitHub (branch `main`) — `build.yml` runs on push.
- [ ] After the first successful run, set the four GHCR packages to public (or
      grant the fleet read access): Settings → Packages.
- [ ] Confirm the four images appear: `school-base`, `school-student`,
      `school-staff`, `school-server`, each with `:latest` + `:stable-YYYYMMDD`.

## 4. Fail-loudly notification (strongly recommended)

- [ ] Wire the `notify-failure` job from the README into `build.yml` and set an
      `ALERT_WEBHOOK` secret. A silently broken build = fleet stops getting
      security updates. This is the single most important operational safeguard.
- [ ] Enable GitHub Actions email/notification for failed **scheduled** runs.

## 5. Tailscale

- [ ] Define the ACL tags in the Tailscale admin console: `tag:svk-student`,
      `tag:svk-staff`, `tag:svk-admin` (and their tagOwners).
- [ ] Decide the auth-key delivery channel for desktops: file on the install
      USB, read by a `tailscale up` at provision time. (Never bake keys in.)
- [ ] Write the actual ACL policy (who can reach the cache, Cockpit, the
      dispenser port 8765, etc.).

## 6. Server first install

- [ ] `butane --pretty --strict server.bu > server.ign` (keep `server.ign` out
      of git — `.gitignore` covers `*.ign`).
- [ ] Install uCore with `coreos-installer install /dev/sdX --ignition-file server.ign`.
- [ ] Provision the 1TB NVMe and mount it at `/var/mnt/registry-cache` (adjust
      `server.bu` if it's a separate disk needing a filesystem + mount unit).
- [ ] Verify the cache: `systemctl status registry.service`, then pull something
      through `svk-server:5000` and confirm it caches.
- [ ] Verify Cockpit is reachable and Tailscale is up as `tag:svk-admin`.

## 7. Hostname pool

- [ ] Define the real pool in `/var/lib/school/hostname-pool` on the server
      (seeded from `hostname-pool.example` on first run — edit the real file,
      not the example). Give yourself more names than machines.

## 8. School specifics to add later

- [ ] Print stack packages + printer config in `build.base.sh`.
- [ ] School CA certs into `files/base/etc/pki/ca-trust/source/anchors/`.
- [ ] Fonts into `files/base/usr/share/fonts/`.
- [ ] System flatpak lists for student/staff.
- [ ] Review the kiosk `# REVIEW:` marker in
      `files/student/usr/bin/reset-student-home.sh` on a real machine
      (logout→reset→autologin timing).

## 9. First fleet machine (smoke test before rolling out all 19)

- [ ] Build a student ISO (Actions → `iso`), install one laptop, confirm:
      autologin, home reset on logout, dconf/polkit lockdown, no Distrobox/Brew,
      Tailscale name from the pool, updates pulling via the cache.
