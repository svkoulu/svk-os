# svk ISOs — Titanoboa (container-native ISO contract)

The two desktop installer ISOs (`svk-student`, `svk-staff`) are built with
[Titanoboa](https://github.com/ublue-os/titanoboa), the same tool Bazzite's live
ISOs use. Titanoboa is pinned to a specific commit
(`5c457c3d0518bd17e754be0fd98a60d29d26abb4`, 2026-05-19) — upstream did a breaking
rewrite around then (`feat!: Only use container images as the only source of
truth`, PR #138) that dropped its old Justfile/`HOOK_post_rootfs` interface
entirely. Titanoboa is now a thin tool: it just squashfs's a container image into
a boot-and-run LiveOS ISO, driven by an `/usr/lib/bootc-image-builder/iso.yaml`
baked **inside the image**. Anaconda, the kickstart, and the offline flatpak bake
are no longer something Titanoboa injects — they're baked into a throwaway
**installer image** (`iso/installer/`) built FROM the real `svk-<flavor>` image
and fed to Titanoboa. That installer image is never pushed anywhere; only the ISO
it produces matters. This is decision **D6** in the rebuild plan; it replaced the
old plain `bootc-image-builder` ISO workflow, and was itself later adapted when
Titanoboa's own interface changed upstream.

## Pieces

| File | Role |
|---|---|
| `flatpaks/common.list` | shared fleet apps, baked into **both** ISOs |
| `flatpaks/student.list` / `staff.list` | per-flavor extras (concatenated with common) |
| `iso/installer/Containerfile` | builds the throwaway installer image `FROM` the real `svk-<flavor>` image |
| `iso/installer/build.sh` | installs Anaconda, writes the kickstart (`bootc switch`es the origin to the signed registry ref, rsyncs the baked `/var/lib/flatpak` onto the target — **no Secure Boot enrollment**, N4), pre-installs the flatpak set into `/var/lib/flatpak`, adds `dracut-live`/`livesys-scripts` for live-boot, and writes `iso.yaml` |
| `iso/build-iso.sh` | wrapper: get the base image into root's podman storage, build the installer image, run pinned Titanoboa against it, collect the ISO |
| `.github/workflows/iso.yml` | manual `workflow_dispatch` build of either/both flavors |

## Dependencies

Beyond the general build dependencies in the top-level `README.md`
(`podman`, `just`), building an ISO also needs:

| Tool | Used for |
|---|---|
| `git` | cloning the pinned Titanoboa commit |
| `rsync` | copying that clone into `iso/.build/<flavor>/` |
| `sudo`, password-authenticated | root podman for the installer-image build (`--cap-add sys_admin`) and Titanoboa's own privileged squashfs/loop-device work |

Install on Fedora: `sudo dnf install git rsync`.
On openSUSE Tumbleweed: `sudo zypper install git rsync`.

**Environment requirements** (learned the hard way — see git history if these
ever need re-diagnosing):
- Run this from a **genuine host shell**, not from inside a distrobox/toolbox/
  devcontainer that bridges commands out to the host (e.g. via
  `distrobox-host-exec`). Unprivileged `podman` calls work fine through such a
  bridge, but `sudo podman ...` doesn't — root can't reach back into the
  bridge's D-Bus session, so every privileged step fails with either
  `command not found` or an unprompted `a password is required`, no matter how
  correct the password is. If `just` itself was installed via
  `distrobox export`, invoking it *still* runs the recipe inside the
  container even from a real host terminal — run `bash iso/build-iso.sh ...`
  directly instead in that case.
- A few GB of free disk headroom (`podman system df` / `podman system prune`
  to check/reclaim) — the installer image build and the squashfs/ISO output
  are each multi-GB.

## Build locally

```bash
# after svk-student / svk-staff are pushed (or built locally with :latest):
iso/build-iso.sh student ghcr     # or: iso/build-iso.sh student local
```

ISO lands at `iso/svk-student-<version>.iso`.

## How updates work after install (D7 — the LAN mirror)

The baked flatpaks live in mutable `/var/lib/flatpak` and update on flatpak's own
timer (not with the OS image). Students update from the school's **curated Flathub
mirror** on `svk-server` over the LAN (no internet). The client wiring that points
`flatpak update` at the mirror is **still TODO** — see the plan's "OPEN (impl)"
item; it repurposes the GPG-key-extraction logic from the old
`svk-flatpak-preinstall.sh` (kept in `archived/`).

## TODOs before ISOs ship

- [x] **Pin Titanoboa** to a real tested commit in `build-iso.sh` (was `@main`,
      which silently rode upstream's breaking container-native rewrite).
- [ ] **Validate an end-to-end build** fix Anaconda profile / kickstart
      as needed.
- [x] **Per-image branding** — done: student/staff stamp their own os-release via
      `/usr/libexec/svk/stamp-os-release`, so fastfetch/tooling report `svk-student` /
      `svk-staff` and the channel build version (not `svk-base`).
- [ ] **LAN-mirror `flatpak update` wiring** (D7) — the client-side remote setup.
- [ ] Confirm the kiosk autologin (`opilas`, sysusers-locked) works post-install.
