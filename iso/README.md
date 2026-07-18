# svk ISOs — Titanoboa (offline flatpak bake)

The two desktop installer ISOs (`svk-student`, `svk-staff`) are built with
[Titanoboa](https://github.com/ublue-os/titanoboa) + Anaconda, the same way
Project Bluefin builds its official ISOs. Titanoboa bakes the curated flatpak set
**into the ISO**, so first boot needs no network and the apps land in system-scope
`/var/lib/flatpak` (surviving a student home-reset). This is decision **D6** in the
rebuild plan; it replaced the old plain `bootc-image-builder` ISO workflow.

> **STATUS: written, NOT yet validated.** The pipeline is derived from the verified
> upstream but has not been run end-to-end (an ISO build needs AC power). Expect the
> first real build to need iteration on the Anaconda/Titanoboa plumbing. The TODOs
> below must be closed before shipping ISOs.

## Pieces

| File | Role |
|---|---|
| `flatpaks/common.list` | shared fleet apps, baked into **both** ISOs |
| `flatpaks/student.list` / `staff.list` | per-flavor extras (concatenated with common) |
| `iso/hook-anaconda.sh` | Titanoboa `HOOK_post_rootfs`: installs Anaconda, kickstart that installs the svk image, `bootc switch`es the origin to the signed registry ref, and rsyncs the baked `/var/lib/flatpak` onto the target. **No Secure Boot enrollment** (N4). |
| `iso/build-iso.sh` | wrapper: assemble the flatpak list, clone pinned Titanoboa, run its `just build`, collect the ISO |
| `.github/workflows/iso.yml` | manual `workflow_dispatch` build of either/both flavors |

## Build locally (needs a real host, root podman, AC power)

```bash
# after svk-student / svk-staff are pushed (or built locally with :latest):
iso/build-iso.sh student ghcr     # or: iso/build-iso.sh student local
```

ISO lands at `iso/svk-student-YYYYMMDD.iso`.

## How updates work after install (D7 — the LAN mirror)

The baked flatpaks live in mutable `/var/lib/flatpak` and update on flatpak's own
timer (not with the OS image). Students update from the school's **curated Flathub
mirror** on `svk-server` over the LAN (no internet). The client wiring that points
`flatpak update` at the mirror is **still TODO** — see the plan's "OPEN (impl)"
item; it repurposes the GPG-key-extraction logic from the old
`svk-flatpak-preinstall.sh` (kept in `archived/`).

## TODOs before ISOs ship

- [ ] **Pin Titanoboa** to a real tested ref in `build-iso.sh` (currently `@main`).
- [ ] **Validate an end-to-end build** on AC power; fix Anaconda profile / kickstart
      as needed.
- [x] **Per-image branding** — done: student/staff stamp their own os-release via
      `/usr/libexec/svk/stamp-os-release`, so fastfetch/tooling report `svk-student` /
      `svk-staff` and the channel build version (not `svk-base`).
- [ ] **LAN-mirror `flatpak update` wiring** (D7) — the client-side remote setup.
- [ ] Confirm the kiosk autologin (`opilas`, sysusers-locked) works post-install.
