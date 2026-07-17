# TODO — admin setup checklist

Things a human must still do before / after this repo builds a working fleet.
The scaffolding is complete; these are the values, secrets, and one-time actions
that (correctly) can't live in git. See `README.md` for the how-to on each.

## 1. Fill in the placeholders (nothing builds until this is done)

Find them all: `grep -rn '<<' . --include=Containerfile.\* --include=\*.sh \
  --include=\*.yml --include=\*.conf --include=\*.json --include=\*.yaml \
  --include=\*.bu --include=\*.nmconnection\*`

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
- [ ] `<<STUDENT_WIFI_SSID>>` / `<<STUDENT_WIFI_PSK>>` — the school's Wi-Fi
      credentials. Copy `files/student/etc/NetworkManager/system-connections/
      svk-student-wifi.nmconnection.example` to the same path minus
      `.example` (gitignored — holds a real secret) and fill both in before
      building `svk-student`. See the README's Wi-Fi lockdown section.
- [x] `<<NEXTDNS_PROFILE_ID>>` — the school's NextDNS profile/config id
      (my.nextdns.io → Setup → Router/Other → DNS-over-TLS), in
      `files/staff/etc/systemd/resolved.conf.d/20-svk-dns.conf`.

## 2. cosign signing

- [x] `cosign generate-key-pair` (press ENTER for an empty password = simplest).
- [x] Commit the real `cosign.pub` over the placeholder at the repo root.
- [x] Add `cosign.key`'s contents as the `COSIGN_PRIVATE_KEY` repo secret.
      (`.gitignore` already blocks committing `cosign.key`.)
- [x] If you set a key password, add it as the `COSIGN_PASSWORD` repo secret.

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
- [ ] Verify the Flathub mirror: `systemctl status svk-flathub-sync.service
      flathub-mirror-serve.service`, then `journalctl -u svk-flathub-sync` for
      the curated-count summary after the first run (it can take a while — it's
      pulling real app content, not just appstream metadata).
- [ ] Verify AdGuard Home: `systemctl status adguard-home.service`, then log
      into `http://svk-server.local:3000` and **set a real admin password**
      (the seeded config ships `users: []` — open dashboard until you do this).

## 7. Hostname pool & other admin-editable data-volume lists

Same pattern for all of these: an `.example` ships in the image, seeded to the
real (editable, image-rebuild-surviving) file on first run; edit the real file
directly on the server, not the example.

- [x] Define the real hostname pool in `/var/lib/svk/hostname-pool` (seeded
      from `hostname-pool.example`). Give yourself more names than machines.
- [ ] Define the real Flathub curation overrides: `/var/lib/svk/flathub-allowlist`
      and `/var/lib/svk/flathub-blocklist` (seeded from the `.example` files in
      `files/server/usr/share/svk/`). Most schools won't need either on day one —
      the automatic filters (license/verification/sandbox/OARS) are the main
      mechanism; these are just the escape hatches.
- [ ] Define the real DHCP scopes for students vs. staff, then replace the
      placeholder CIDRs in `clients.persistent` in AdGuard Home's config
      (`http://svk-server.local:3000` → Settings → Client Settings, or edit
      `AdGuardHome.yaml` on the data volume directly) so per-client filtering
      differences actually take effect.

## 8. School specifics to add later

- [ ] Print stack packages + printer config in `build.base.sh`.
- [ ] School CA certs into `files/base/etc/pki/ca-trust/source/anchors/`.
- [ ] Fonts into `files/base/usr/share/fonts/`.
- [x] System flatpak list shipped (`files/base/etc/svk/flatpaks.list`, installed
      by `svk-flatpak-preinstall.service`). Add per-image extras under
      `files/{student,staff}/etc/svk/flatpaks.list.d/*.list` if needed.
- [x] Decide the real Firefox extension set + settings in
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
- [ ] **uBlock Origin managed policy** actually applied: open uBO's dashboard →
      *Filter lists* and confirm the Social widgets list is checked on a student
      machine and unchecked on staff (`3rdparty.Extensions` key in
      `policies.json`). uBO's managed-storage schema has changed shape before
      (see the comment in `policies.json`) — if the lists aren't reflected,
      re-check them against `github.com/gorhill/uBlock`'s current wiki.
- [ ] **Student Wi-Fi lockdown**: confirm a student cannot add a second Wi-Fi
      network (Quick Settings should offer no "Connect to Network" option that
      does anything), and that toggling Wi-Fi off in Quick Settings no-ops.
      Then specifically test **rfkill / airplane mode** — it sometimes bypasses
      polkit entirely via udev `uaccess` seat tagging, which would let a student
      drop the connection anyway. If it does, this needs a fix beyond
      `49-school-lockdown.rules` (e.g. masking the airplane-mode hotkey/action).
- [ ] **DNS fail-closed on students**: pull a student laptop off the school
      Wi-Fi's AP (or block it at the router) and confirm name resolution fails
      rather than silently falling back to an unfiltered upstream. Also check
      that NetworkManager isn't pushing a DHCP-supplied nameserver into
      `resolved` ahead of the baked `resolved.conf.d` config (see the comment
      in `files/student/etc/systemd/resolved.conf.d/20-svk-dns.conf` — the fix
      would be `ignore-auto-dns=yes` on the baked Wi-Fi profile).
