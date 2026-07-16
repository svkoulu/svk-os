# Flathub cache, AdGuard Home DNS, student Wi-Fi lockdown, uBlock Origin lists

Status: spec agreed, not yet implemented.

## 1. Flathub caching

- Mirror a **curated set** of Flathub refs into a local OSTree repo on the
  server (not the whole catalog — impractical size, and staff self-serve needs
  vetting anyway).
- Storage: **named podman volume** (alongside the existing `registry-cache`
  quadlet pattern).
- Refresh: **daily** systemd timer (`ostree pull --mirror`), no bespoke
  fallback logic needed — daily is enough.
- Serve the mirror over HTTP (nginx/Caddy quadlet next to `registry-cache`).
- Client side: add the mirror as a **second, higher-priority flatpak remote**
  alongside the real `flathub` remote (`flatpak remote-add --prio`) so any ref
  not mirrored falls through to real Flathub automatically.
- Scope: staff get this as a **browsable GNOME Software catalog** (self-serve
  install allowed on staff machines). Students stay locked to the fixed
  preinstalled `flatpaks.list` set regardless of what's in the broader mirror —
  their `org/gnome/software allow-updates=false` dconf lock already blocks
  install/update from Software, so the curated catalog doesn't need separate
  gating for them.

### Curation filters (all must pass for auto-include)

1. **License** — exclude `project_license == LicenseRef-proprietary` (FOSS
   only). Source: Flathub's `appstream.xml.gz`, already available from the
   same OSTree repo being mirrored — no separate API dependency.
2. **Verification** — exclude apps without Flathub's verified-developer flag.
   Likely exposed as a custom appstream field (something like
   `flathub::verification::verified` under `<custom>`) — confirm the exact key
   against Flathub's current appstream schema at implementation time rather
   than trust this from memory.
3. **Sandbox permissions** — exclude apps requesting broad host access.
   Checkable directly from the mirrored ref's own `/metadata` file
   (`[Context]` section: `filesystems=`, `sockets=`, `devices=`) — exclude
   anything with e.g. `filesystem=host`, `socket=session-bus`, `device=all`.
   No need to fetch build manifests separately.
4. **OARS content rating** — exclude anything where any `violence-*` or
   `sex-*` category in `<content_rating>` is rated above `none` (cartoon /
   fantasy / realistic violence, bloodshed, nudity, sexual themes — all must be
   `none`).
5. ~~Age / first-published-date filter~~ — explicitly **not** wanted.

### Manual overrides

- `flatpak-allowlist` — force-include even if a filter fails (e.g. trusted but
  unverified app).
- `flatpak-blocklist` — force-exclude even if all filters pass.
- Same flat-file shape as the existing `flatpaks.list` / `flatpaks.list.d`
  pattern.
- If an app ends up on **both** lists, block-list wins; the sync script should
  warn loudly on that case rather than silently pick one.

## 2. DNS: caching + blocklists (AdGuard Home)

- Run **AdGuard Home** on the server as a podman quadlet (does caching +
  blocklists + per-client config in one process — matches the
  student-vs-staff split without extra tooling).
- Blocklists: **self-hosted lists primary**, **NextDNS as fallback upstream**
  (not the other way around) — gives fast local caching + filtering on campus,
  and roaming staff laptops stay filtered off-network without depending on
  reaching the server.
- Client resolver config (`resolved.conf.d`, per-image):
  - **Students** (LAN-only, never leave campus): `DNS=svk-server.local` only,
    no fallback. Fail-closed is the correct behavior for a kiosk.
  - **Staff** (roam off-site, already on Tailscale): `DNS=svk-server.local
    <NextDNS DoT endpoint>` with `DNSOverTLS=opportunistic` — local cache +
    self-hosted lists on-LAN, automatic fallback to NextDNS (staff profile)
    once off-site.

## 3. Lock student Wi-Fi to a single network

- Bake exactly **one** system Wi-Fi connection profile into
  `files/student/etc/NetworkManager/system-connections/<ssid>.nmconnection`
  (autoconnect, root-owned). The existing polkit rule
  (`files/student/etc/polkit-1/rules.d/49-school-lockdown.rules`) already
  denies `opilas` all `NetworkManager.settings.*` actions, so opilas cannot add
  a second profile — this becomes the only network the machine can ever join.
- Extend that same polkit rule to also deny, for `opilas`:
  - `org.freedesktop.NetworkManager.enable-disable-wifi`
  - `org.freedesktop.NetworkManager.enable-disable-network`
  - `org.freedesktop.NetworkManager.network-control`
  so the Quick Settings Wi-Fi toggle / "Disconnect" no-ops instead of dropping
  the connection.
- **Open edge case to verify on real hardware**: the rfkill / "airplane mode"
  toggle sometimes bypasses polkit entirely (udev `uaccess` seat tagging).
  Flag as a hardware-verification TODO (same pattern as the other
  verify-on-hardware items already in `TODO.md` §11) rather than guessing at a
  fix now.

## 4. uBlock Origin list config via Firefox managed policy

- Mechanism: Firefox's `3rdparty.Extensions` managed-storage key
  (`policies.json`), which uBO reads on startup.
- Firefox only reads **one** `policies.json` — no merging across files like
  `flatpaks.list.d` — so student and staff each need their **own full copy**
  of `policies.json` (same pattern as `tailscale.conf`: base ships a generic
  default never deployed standalone, each derived image ships a complete
  override).
- **Students**: enable every uBO list category, including cosmetic filtering
  and the Social-widgets list.
- **Staff**: enable every list category **except** Social.
- Exact managed-storage key names (e.g. the Social list's asset key) to be
  pulled from uBO's published `managed_storage_schema.json` at implementation
  time — don't guess from memory.

## Open items carried into implementation

- Confirm Flathub verification appstream key name.
- Confirm uBO managed-storage schema key names / social list asset id.
- Verify rfkill/airplane-mode behavior on real student hardware after the
  polkit changes land.
