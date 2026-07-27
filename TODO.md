# TODO — admin setup checklist

What a human still needs to do to get from this repo to a running fleet. Reflects
the **modular rebuild** (svk now builds `FROM` raw Fedora Silverblue + svk config,
not `FROM bluefin`; ISOs bake flatpaks offline via Titanoboa). Items marked
`[x]` are done in-repo; `[ ]` need a person. See `README.md` for the how-to.

## 0. Rebuild status (where the code is)

- [x] The desktop image rebuilt on Silverblue; builds green (`bootc container lint
      --fatal-warnings`), verified locally.
- [x] `svk-base` / `svk-student` / `svk-staff` **collapsed into a single `svk-os`**
      (2026-07-27). One image for lab machines and staff laptops; the installer
      decides which accounts exist. **Needs a fresh local build + on-hardware
      re-validation** — see `tasks/done/…-single-image-collapse.md`.
- [x] `svk-server` **split into its own repo** (`../svk-server`, 2026-07-27) —
      server code, `server.bu`, `secrets/` and its build all moved there. Its
      remaining setup steps live in that repo's `TODO.md`.
- [x] CI (`build.yml`) adapted; merged to `main`.
- [ ] **Confirm the first CI build on `main` is green** (Actions tab). Watch-item:
      the runner's podman must support `RUN --mount=type=bind,from=stage` +
      `type=cache` (ubuntu-24.04 / podman 4.9 expected fine).
- [x] **After the first green build, make the GHCR packages public** (or grant
      the fleet read access): Settings → Packages. Pushing to `main` publishes the
      **testing** channel (`:testing` + `:latest` + `:testing-YYYYMMDD`); the fleet's
      **stable** channel (`:stable` + `:stable-N` + `:stable-N-YYYYMMDD`) appears only
      after you cut the first **git tag** (e.g. `git tag 1 && git push --tags`).
      Confirm `svk-os` shows the tags.
- [ ] **`svk-base` / `svk-student` / `svk-staff` are no longer published.** Any
      machine already installed from them must be moved over:
      `sudo bootc switch --enforce-container-sigpolicy ghcr.io/svkoulu/svk-os:stable`.
      Delete the three stale GHCR packages once nothing tracks them.

## 1. Finish Phase 5 — ISOs (Titanoboa) — needs AC power

The ISO pipeline (`iso/`) is written but **NOT yet validated end-to-end**. See
`iso/README.md`. Note: upstream Titanoboa did a breaking rewrite (PR #138,
2026-05-19) that dropped its old Justfile/`HOOK_post_rootfs` interface and
Anaconda entirely — the pipeline was adapted to the new container-native
contract (a throwaway `iso/installer/` image now bakes Anaconda + the kickstart +
flatpaks + live-boot support, instead of Titanoboa injecting a hook).

- [ ] Run one ISO build (`just iso local`) and fix any Anaconda/Titanoboa plumbing
      it surfaces. **One ISO now**, with the lab/staff role picked from the GRUB
      menu at boot.
- [x] **Unattended install automation** (`iso/installer/build.sh`): Finnish
      language + keyboard, Europe/Helsinki timezone, full-disk btrfs auto-partition
      with LUKS encryption — all preset in the kickstart so nothing prompts.
      **Both roles zero-click** from their own automated GRUB entry, under
      `inst.cmdline` so a kickstart gap aborts visibly: lab creates `opilas`
      (locked, autologin) + the kiosk role `%post`; staff creates the placeholder
      `staff` login with an **expired** password. *Needs on-hardware validation
      (below).*
- [ ] **Validate on hardware: TPM2 auto-unlock.** LUKS is created with a throwaway
      bootstrap passphrase; the TPM2 is **pre-enrolled at install time**
      (`svk-luks-tpm.ks` `%post`, PCR 7) and the kickstart adds
      `rd.luks.options=tpm2-device=auto` to the kernel args, so a TPM machine should
      **auto-unlock from first boot** with no prompt. The first-boot
      `svk-luks-tpm-enroll.service` (`files/os/usr/libexec/svk/luks-tpm-enroll`)
      then shows a **per-machine recovery key + QR on tty1** (photograph it — shown
      once, never retrievable) and wipes the bootstrap slot. **Confirm auto-unlock**
      (test with `swtpm` in a UEFI VM first). The bootstrap passphrase is only a
      fallback for TPM-less machines.
- [x] Pin Titanoboa to a real tested commit in `iso/build-iso.sh` (was `@main`).
- [x] **Image branding + metadata** — done. The image stamps its os-release
      (`NAME`/`IMAGE_ID`/`IMAGE_VERSION`) **and** `/usr/share/svk-os/image-info.json`
      (channel/version/release-tag/base/fedora) via `/usr/libexec/svk/stamp-os-release`,
      so a machine reports `svk-os` + the channel build version.
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
      fill the real (gitignored) `.nmconnection` before building `svk-os`.
- [ ] Server secrets (outbound SSH key, tailscale pre-auth key) → moved to
      `../svk-server/TODO.md`. The SSH key's `.pub` half must still match the
      `svk-server` line in `files/os/etc/ssh/authorized_keys.d/admin`.
- [x] `<<GHCR_NAMESPACE>>` → `svkoulu`; `<<REGISTRY_CACHE_HOST>>` →
      `svk-server.local`; `<<ADMIN_SSH_PUBLIC_KEY>>`; `<<NEXTDNS_PROFILE_ID>>` — set.
- [ ] Optional: school packages in `build/10-packages.sh` (`<<ADD ... HERE>>`),
      print stack, fonts (`files/os/usr/share/fonts/`), CA certs
      (`files/os/etc/pki/ca-trust/source/anchors/`).
- [ ] **Staff password.** The kickstart bakes a placeholder and expires it
      immediately (`chage -d 0`), so the teacher must set a real one at first login;
      override the baked value with `STAFF_PASSWORD=… iso/build-iso.sh …`. With the
      lab/staff boundary now scoped to the *account*, this is load-bearing. Real fix:
      `tasks/todo/20260719-0110-usb-provisioning-config.md`.
- [ ] **Tailscale enrolment is off by default fleet-wide** (`TAILSCALE_ENROLL="no"`
      in `files/os/etc/svk/tailscale.conf`) — one image can't know it's a staff
      laptop. Until the USB provisioning config lands, opt a staff laptop in by hand:
      edit that file on the machine, then `systemctl start svk-tailscale-enroll`
      with the SVK-PROV USB inserted.

## 5. Server first install (uCore / Ignition)

Moved with the code — see [`../svk-server/TODO.md`](../svk-server/TODO.md).

## 6. Tailscale, hostnames, data-volume lists

- [x] Tailscale ACL tags/policy + USB (`SVK-PROV`) enrol flow shipped.
- [ ] Prepare the `SVK-PROV` USB: filesystem label `SVK-PROV`, file
      `tailscale-authkey` = a **reusable** `tag:svk-staff` pre-auth key (short
      expiry; revoke after provisioning). The ACL tag stays `tag:svk-staff`; the
      image's own default is now the neutral `tag:svk-node` with enrolment off, so
      the USB is only consumed on machines opted in by hand (or, later, by the USB
      provisioning config).
- [ ] Server-side lists (hostname pool, Flathub curation overrides, AdGuard DHCP
      scopes) → `../svk-server/TODO.md`. Note the image now ships ONE NextDNS
      profile fleet-wide (the stricter former student one) — per-machine DNS moves
      to the USB provisioning config.

## 7. First fleet machine — smoke test (before rolling out all ~19)

Build the ISO, install one laptop of each role, and verify **on real hardware**:

- [ ] **Zero-click install, both roles**: booting the ISO and picking either install
      entry partitions, encrypts, installs and reboots with **no prompts** (Finnish
      UI + `fi` keyboard, Helsinki time).
- [ ] **Account scoping holds** (the whole basis of the single image): on a **staff**
      machine there is no `opilas`, the kiosk units log as *skipped* (not failed),
      the dconf lockdown is absent, and Bluetooth is not blocked at boot. On a **lab**
      machine the lockdown is present. A machine with no `opilas` must never end up
      with an unlocked kiosk profile — confirm inert, not absent.
- [ ] **Per-account app restrictions**: `staff` can launch gnome-software but not
      Terminal/Disks/System Monitor/Tweaks/Firewall (and doesn't see their icons);
      `opilas` can launch none of the six; `admin` can launch all of them from a GUI
      session. Check gnome-software's background `--gapplication-service` autostart
      fails **quietly** for `opilas`.
- [ ] **`admin` can actually reach the GUI.** sysusers creates it with a *locked*
      password, so "Not listed?" at the greeter will refuse it until a password is
      set. Decide and document how an operator gets a local GUI session.
- [ ] **Staff flatpak install works**: `staff` installs an app from gnome-software
      with **no admin password prompt**, it lands in **system scope**
      (`flatpak list --system`), and `opilas` can see and launch it.
- [ ] **Disk encryption + TPM**: at first boot the recovery key + QR appear on the
      console (photograph + file it); after acknowledging, subsequent boots
      **auto-unlock via the TPM with no passphrase prompt**; the bootstrap slot is
      gone (`systemd-cryptenroll --list` / `cryptsetup luksDump`).
- [ ] **Autologin** into `opilas` (created **locked by the kickstart**, not
      sysusers.d any more — confirm GDM autologin still works), **home reset** on
      logout, dconf/polkit **lockdown**.
- [ ] **Baked flatpaks present offline** (`flatpak list --system` — all 16 in
      `flatpaks/common.list`) and **survive a logout/home-reset** (they're
      system-scope, not in `/home/opilas`). Confirm the prepended `XDG_DATA_DIRS`
      did **not** cost the flatpak app-grid entries: flatpak's own environment
      generator runs after systemd's and appends its export dirs, so both should
      coexist.
- [ ] **Flatpak updates pull from the LAN mirror** (once §1 wiring lands), not the
      internet.
- [ ] **Firefox policy + uBlock Origin** active (`about:policies`, uBO dashboard).
      One policy fleet-wide now: the Social lists are checked **everywhere**,
      including staff laptops.
- [ ] **admin SSH** from the LAN; **image auto-updates** pull through the cache.
- [ ] **Update timers match the schedule**: `systemctl list-timers
      bootc-fetch-apply-updates.timer svk-flatpak-update.timer` — desktops and
      server both weekly (Monday), with the documented `RandomizedDelaySec`. The
      former student-monthly cadence is gone: desktops **stage only** (confirm
      `systemctl cat bootc-fetch-apply-updates.service` shows no `--apply`), so a
      weekly check never reboots mid-class, while the server still applies
      immediately. `ujust update-status` should agree. See
      `tasks/todo/…-fleet-update-cadence.md`.
- [ ] **Lab Wi-Fi lockdown**: can't add a second network; Wi-Fi toggle no-ops;
      test **rfkill/airplane mode** (can bypass polkit via udev `uaccess`).
- [ ] **DNS** resolves through `svk-server.local` on campus and falls back to
      NextDNS off it (one profile fleet-wide now, not the old per-flavor split).
- [ ] **Power switching**: `power-saver` on battery, `balanced` on AC
      (`powerprofilesctl get` after plug/unplug).
- [ ] Review the `# REVIEW:` marker in `files/os/usr/bin/reset-opilas-home.sh`
      (logout→reset→autologin timing).
