# TODO — admin setup checklist

Things a human must still do before / after this repo builds a working fleet.
The scaffolding is complete; these are the values, secrets, and one-time actions
that (correctly) can't live in git. See `README.md` for the how-to on each.

## 1. Fill in the placeholders (nothing builds until this is done)

Find them all: `grep -rn '<<' . --include=Containerfile.\* --include=\*.sh \
  --include=\*.yml --include=\*.conf --include=\*.json --include=\*.yaml --include=\*.bu`

- [x] `<<GHCR_NAMESPACE>>` — GitHub user/org that owns the images. Replace in the
      Containerfiles, `build.yml`, `iso.yml`, `policy.json`, `registries.d/ghcr-svk.yaml`,
      and `server.bu`.
- [x] `<<REGISTRY_CACHE_HOST>>` — DONE: set to `svk-server.local` (mDNS), so
      LAN-only student machines resolve it too, not just tailnet members.
      `svk-server.local:5000` in the mirror drop-in; bare host in the claim script.
- [x] `<<ADMIN_SSH_PUBLIC_KEY>>` — DONE: admin operator key baked into every
      device (`files/base/etc/ssh/authorized_keys.d/admin`) and into `server.bu`.
- [x] `secrets/id_ed25519` — the server's OUTBOUND ssh private key (a **file**,
      not an inline placeholder; injected at compile time via `butane --files-dir`,
      gitignored). `ssh-keygen -t ed25519 -C svk-server -N '' -f secrets/id_ed25519`.
      Its public half is already the `svk-server` line in the desktops'
      `authorized_keys.d/admin`; if you regenerate, paste the new `.pub` there
      and rebuild. See `secrets/README.md`.
- [x] `secrets/tailscale-authkey` — server's one-off pre-auth key (file,
      gitignored, injected at compile time). Delete from the console after first
      install.
- [x] `<<ADD ... HERE>>` — optional system-package / flatpak / font lists in
      `build.base.sh`, `build.student.sh`, `build.staff.sh`.

## 2. cosign signing

- [x] `cosign generate-key-pair` (press ENTER for an empty password = simplest).
- [x] Commit the real `cosign.pub` over the placeholder at the repo root.
- [ ] Add `cosign.key`'s contents as the `COSIGN_PRIVATE_KEY` repo secret.
      (`.gitignore` already blocks committing `cosign.key`.)
- [ ] If you set a key password, add it as the `COSIGN_PASSWORD` repo secret.

## 3. GitHub / GHCR

- [ ] Push this repo to GitHub (branch `main`) — `build.yml` runs on push.
- [ ] After the first successful run, set the four GHCR packages to public (or
      grant the fleet read access): Settings → Packages.
- [ ] Confirm the four images appear: `svk-base`, `svk-student`,
      `svk-staff`, `svk-server`, each with `:latest` + `:stable-YYYYMMDD`.

## 4. Fail-loudly notification (strongly recommended)

- [ ] Wire the `notify-failure` job from the README into `build.yml` and set an
      `ALERT_WEBHOOK` secret. A silently broken build = fleet stops getting
      security updates. This is the single most important operational safeguard.
- [ ] Enable GitHub Actions email/notification for failed **scheduled** runs.

## 5. Tailscale (main devices only — 50-device cap)

Students are NOT on the tailnet (they'd blow the ~50-device limit); they're
reached over the LAN instead. Only server/staff/admin get tagged.

- [x] Define the ACL tags + tagOwners in the Tailscale admin console:
      `tag:svk-admin` (IT operator laptops), `tag:svk-server` (the cache/jump
      host), `tag:svk-staff` (staff desktops). Keep the `tag:svk-student` *file*
      in the image (the claim script reads it for the hostname prefix) but do
      NOT enroll students. If you want the server distinct from operators in the
      ACL, change `TAILSCALE_TAG` in `files/server/etc/svk/tailscale.conf` to
      `tag:svk-server`.
- [x] Write the ACL/SSH policy: admin → Tailscale-SSH → server + staff; the
      server then SSHes to students over the LAN (svk-*.local) with its baked
      key. See the ACL JSON in the README networking section.
- [x] Staff auth-key delivery: IMPLEMENTED as a provisioning USB. Base ships
      `svk-tailscale-enroll.service`, which reads the key from a USB labelled
      `SVK-PROV` (file `tailscale-authkey`) and enrols per
      `/etc/svk/tailscale.conf`. Students skip it (`TAILSCALE_ENROLL=no` +
      `build.student.sh` disables tailscaled).
- [ ] Prepare the `SVK-PROV` USB: format a stick/partition with filesystem label
      `SVK-PROV`, and write the key to a file named `tailscale-authkey`. Use a
      **reusable**, `tag:svk-staff` pre-auth key (short expiry) since one USB
      enrols many staff laptops; revoke it in the console after provisioning.
      The same USB is safe to have plugged in while installing student machines
      (they ignore it).

## 6. Server first install

- [ ] `butane --pretty --strict --files-dir . server.bu > server.ign` (the
      `--files-dir` pulls in `secrets/`; keep `server.ign` out of git — it holds
      the secrets in cleartext; `.gitignore` covers `*.ign`).
- [ ] Install uCore with `coreos-installer install /dev/sdX --ignition-file server.ign`.
- [ ] Provision the 1TB NVMe and mount it at `/var/mnt/registry-cache` (adjust
      `server.bu` if it's a separate disk needing a filesystem + mount unit).
- [ ] Verify the cache: `systemctl status registry.service`, then pull something
      through `svk-server:5000` and confirm it caches.
- [ ] Verify Cockpit is reachable and Tailscale is up as `tag:svk-admin`.

## 7. Hostname pool

- [ ] Define the real pool in `/var/lib/svk/hostname-pool` on the server
      (seeded from `hostname-pool.example` on first run — edit the real file,
      not the example). Give yourself more names than machines.

## 8. School specifics to add later

- [ ] Print stack packages + printer config in `build.base.sh`.
- [ ] School CA certs into `files/base/etc/pki/ca-trust/source/anchors/`.
- [ ] Fonts into `files/base/usr/share/fonts/`.
- [x] System flatpak list shipped (`files/base/etc/svk/flatpaks.list`, installed
      by `svk-flatpak-preinstall.service`). Add per-image extras under
      `files/{student,staff}/etc/svk/flatpaks.list.d/*.list` if needed.
- [ ] Decide the real Firefox extension set + settings in
      `files/base/etc/firefox/policies/policies.json` (uBlock Origin is shipped
      as a starter). Add each extension's AMO `install_url` and any homepage /
      bookmarks / locked prefs. Consider a stricter `installation_mode: blocked`
      for the student image (per-image policies.json override).
- [ ] Review the kiosk `# REVIEW:` marker in
      `files/student/usr/bin/reset-opilas-home.sh` on a real machine
      (logout→reset→autologin timing).

## 9. Desktop defaults to verify on real hardware

- [ ] Reconcile `enabled-extensions` in
      `files/base/etc/dconf/db/local.d/00-svk-desktop` with Bluefin's stock list
      (`gsettings get org.gnome.shell enabled-extensions` on an unmodified
      image) — the key REPLACES the list, so shipping only `ding@rastersoft.com`
      would disable Bluefin's other default extensions. Fold DING into the real
      list, and confirm the DING UUID is right (else desktop icons won't appear).
- [ ] Confirm window buttons (min/max/close), calendar week numbers, and the
      clock weekday show for both a staff and an opilas login.
- [ ] Confirm power switching: profile goes `power-saver` on battery and
      `balanced` on AC (`powerprofilesctl get` after plug/unplug).

## 10. First fleet machine (smoke test before rolling out all 19)

- [ ] Build a student ISO (Actions → `iso`), install one laptop, confirm:
      autologin (opilas), home reset on logout, dconf/polkit lockdown, no
      Distrobox/Brew, admin SSH from the LAN, updates pulling via the cache.

## 11. Runtime behaviours to verify on real hardware

- [ ] **Which updater is active?** `systemctl list-timers` on a desktop. This
      repo jitters `uupd.timer` AND `bootc-fetch-apply-updates.timer` (2h random
      delay) but only one drives updates on Bluefin. If it's neither, move the
      `10-svk-randomize.conf` drop-in to the timer that is. The server uses the
      bootc timer (enabled in `build.server.sh`).
- [ ] **Flatpak preinstall** runs on first boot: `systemctl status
      svk-flatpak-preinstall`; confirm Firefox/LibreOffice/VLC/GIMP/VideoTrimmer/
      OpenShot/LosslessCut appear (`flatpak list --system`). Note these pull from
      Flathub (not the ghcr cache), so first boot needs internet.
- [ ] **Firefox policies** reach the flatpak: open `about:policies` — the
      shipped policies (and uBlock Origin under `about:addons`) should be active.
      If not, the `/etc/firefox` flatpak override didn't take; check
      `flatpak info --show-permissions org.mozilla.firefox`.
