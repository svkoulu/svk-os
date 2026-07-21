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
| `iso/installer/build.sh` | installs Anaconda (+`tmux`, needed by `anaconda.service`), writes the kickstart (localization + auto-partition + LUKS, `bootc switch`es the origin to the signed registry ref, rsyncs the baked `/var/lib/flatpak` onto the target — **no Secure Boot enrollment**, N4), pre-installs the flatpak set into `/var/lib/flatpak`, adds `dracut-live`/`livesys-scripts` for live-boot, and writes `iso.yaml` |
| `iso/build-iso.sh` | wrapper: get the base image into root's podman storage, generate a per-build LUKS bootstrap passphrase, build the installer image, run pinned Titanoboa against it, collect the ISO |
| `files/base/usr/libexec/svk/luks-tpm-enroll` (+ `.service`) | first-boot: TPM2 auto-unlock enrollment + on-screen per-machine recovery key (shipped in the base image, not the ISO) |
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

## Boot menu: two paths, one squashfs

Each ISO offers two ways to boot, both from the same live filesystem:

| GRUB entry | What it does |
|---|---|
| **0 — `Install … - automated, ERASES THE DISK`** (default, 15s) | Boots `systemd.unit=anaconda.target` — the same code path a Fedora **boot.iso** uses — and hands Anaconda the complete kickstart via `inst.kickstart=`. Zero clicks: installs, then reboots. Text UI on the console (no `quiet rhgb`), so provisioning is watchable. |
| **1/2 — `Live desktop …`** (plain / basic graphics) | The normal live GNOME session, fully featured (browser, terminal, disk tools) for triage and recovery. Installing from it via *Install to Hard Drive* works, but **interactively** — see below. |

> ⚠️ The automated entry is the **default** and erases the target disk after a 15s
> timeout. Don't leave a provisioning USB in a machine you're only rebooting.

**Why the automated path can't just be the live session with a kickstart** — this
is the trap the ISO fell into before, and the reason for the split:

1. `/usr/bin/liveinst` (from `anaconda-live`) greps `/proc/cmdline` for `inst.ks=`,
   prints *"Kickstart is not supported on Live ISO installs, please use netinstall
   or standard ISO. This installation will continue interactively."*, and then
   **drops it** — it always execs the fixed `anaconda --liveinst --graphical`.
2. Even if it passed the file through, Anaconda ignores it:
   `startup_utils.find_kickstart()` is gated on `if options.ksfile and not
   options.liveinst`. Under `--liveinst` the *only* kickstart it will read is
   `/usr/share/anaconda/interactive-defaults.ks`.

Hence the automated entry avoids `--liveinst` altogether by booting
`anaconda.target`. Two consequences baked into `iso/installer/build.sh`:

- **`tmux` must be installed.** `anaconda.service` is literally
  `tmux -f /usr/share/anaconda/tmux.conf start`, and that tmux.conf is what spawns
  `anaconda` (plus the `log`/`storage-log`/`packaging-log` windows — handy during
  a failed install). `anaconda-direct.service` doesn't avoid it either; it
  `Requires=anaconda.service`. Silverblue ships no tmux.
- **`inst.kickstart=<path>`, not `inst.ks=`.** Anaconda's `--ks` is a
  `store_const` that always resolves to `/run/install/ks.cfg` (normally fetched by
  the dracut `anaconda` module, which this live initramfs doesn't include) — the
  value after `inst.ks=` is parsed and thrown away. `--kickstart` is the variant
  that takes a path, and it wants a plain path, not a `file://` URL.

The live-desktop path gets `interactive-defaults.ks` populated with the
`ostreecontainer` line and the same `%post` steps. That is **not** cosmetic: an
empty `interactive-defaults.ks` makes Anaconda fall back to `LiveOSPayload`, which
would write the throwaway installer rootfs to disk as a plain, non-bootc system
that never updates. What it deliberately omits is the `%pre`-minted LUKS
passphrase, `autopart`, the account and `reboot` — the operator supplies those. A
machine installed this way therefore gets **no TPM enrollment** and prompts for the
operator's passphrase on every boot. It's a fallback for odd hardware, not the
fleet's provisioning route.

## Install automation & disk encryption

The kickstart pre-answers every Anaconda step, so **both** flavors install with no
manual steps from the **automated** GRUB entry:

| | student | staff |
|---|---|---|
| Delivery | complete kickstart via `inst.kickstart=` (`svk-student.ks`) | complete kickstart via `inst.kickstart=` (`svk-staff.ks`) |
| Manual steps | **none** — installs and reboots on its own | **none** — installs and reboots on its own |
| Account | baked `opilas` (sysusers.d); root locked | baked `staff` login (regular user, no sudo); root locked |
| Language / keyboard | Finnish (`fi_FI.UTF-8`, `fi` layout) | same |
| Timezone | Europe/Helsinki | same |
| Disk | wipe all disks → btrfs autopart, LUKS-encrypted | same |

The staff account is currently a **placeholder** — username `staff`, password
`stafff` (6 chars to clear Anaconda's default `pwpolicy user --minlen=6`), a regular
non-sudo user (local admin is intentionally SSH-only via the `admin` account). It
exists to confirm staff can install fully unattended; the per-site **USB
provisioning config** (`tasks/todo/20260719-0110-usb-provisioning-config.md`) will
replace it with the real account(s) read from the SVK-PROV USB. **Change the staff
password on first login / before the fleet ships.**

**Disk encryption (LUKS + TPM2).** There is **no secret in the ISO.** The LUKS
passphrase is **generated per install**, in the kickstart's `%pre` (see the
`common_ks` block in `iso/installer/build.sh`): each machine gets a unique,
throwaway 32-char passphrase, written to the autopart line via `%include` and
stashed on the target as `/etc/svk/luks-bootstrap` for enrollment. Nothing is baked
into the installer image, and `build-iso.sh` neither prints nor saves a passphrase.

The **TPM2 is pre-enrolled at install time** (`svk-luks-tpm.ks` `%post`, bound to
**PCR 7** — the only PCR that's identical in the installer and the installed system
on the same machine), and the kickstart adds `rd.luks.options=tpm2-device=auto` to
the kernel args. So a machine with a TPM **auto-unlocks from the very first boot**,
no passphrase prompt. On that first boot, `svk-luks-tpm-enroll.service` (from the
base image):

1. enrolls a **unique per-machine recovery key**, shown once on `tty1` with a QR
   code — **photograph it during provisioning; it can never be retrieved again**;
2. confirms the TPM2 enrollment (or enrolls it as a fallback if install-time failed);
3. adds `tpm2-device=auto` to `/etc/crypttab` (belt-and-suspenders);
4. **wipes the per-install passphrase slot** and deletes the file, so nothing that
   existed at install can unlock a deployed machine.

It self-disables afterwards and is a no-op on unencrypted (dev/local) installs.

**No-TPM machines.** With no shared passphrase to print, the fallback for a machine
that can't enroll a TPM (so first boot stops at the disk-unlock prompt) is:
attended, capture the one-time per-install passphrase from the installer console
**before the auto-reboot** — switch to a VT with `Ctrl+Alt+F2` and run
`cat /tmp/svk-luks-bootstrap`. The proper fix is the **USB provisioning config**
(`tasks/todo/20260719-0110-usb-provisioning-config.md`), which will write the
per-machine passphrase to the physically-controlled SVK-PROV USB instead. On
target hardware (TPM 2.0 standard), this path is not normally hit.

⚠️ **Not yet validated on hardware** — confirm a TPM machine auto-unlocks (test it in
a VM with an emulated TPM first: `just run-iso <flavor>`, see below). If it still prompts
every boot despite a TPM, the initramfs isn't honouring `rd.luks.options`; the recovery
key always works meanwhile.

## Build metadata & provenance — where to find it

Every ISO carries its provenance in several places, from "readable without booting"
to "baked deep inside." When correlating a machine, an ISO, or a captured log bundle
with the exact source it came from, look here:

| File | Where it lives | Contains | How to read it |
|---|---|---|---|
| `iso/svk-<flavor>-<version>.build-info.json` | **Next to the ISO**, and in the CI artifact zip alongside it | flavor, channel, image-ref, image-version, **packaged-image commit**, **iso/ scripts commit**, iso filename, build timestamp | open the file (no boot/unsquash needed) — the fast path |
| CI artifact name | GitHub Actions | `svk-<flavor>-<channel>-<shortsha>-iso` | the downloaded zip's name is self-identifying |
| `/usr/share/svk-os/iso-build-info.json` | Inside the ISO's **live/installer env** (the squashfs) | flavor, image-ref, **iso/ scripts commit**, built-at | boot the installer and `cat` it, or `unsquashfs` `LiveOS/squashfs.img` |
| `/usr/share/svk-os/image-info.json` | Inside the **installed image** | image identity + **`git-commit`** of the packaged image | on a running machine, `cat` it |
| os-release `BUILD_ID` / `IMAGE_VERSION` | Inside the **installed image** | packaged-image commit / version string | `cat /etc/os-release` on a running machine |

The `.build-info.json` sidecar is the deliberate answer to "which commit is this
downloaded ISO?" — the deeper copies (squashfs, installed image) can only be read
after booting or unsquashing. The sidecar is produced by `iso/build-iso.sh` and
uploaded by `.github/workflows/iso.yml`; it is a build output (gitignored), **not**
a secret — the per-install LUKS passphrase is minted at install time and appears in
none of these files.

## Test the ISO in a VM (`just run-iso`)

`just run-iso <flavor>` boots the newest locally-built `iso/svk-<flavor>-*.iso` in a
throwaway VM to exercise the whole install → reboot → first-boot path end-to-end,
**including LUKS + TPM auto-unlock**. It runs the [`qemux/qemu`](https://github.com/qemus/qemu)
container (needs `/dev/kvm` + `podman`, but **no host qemu or swtpm**): `BOOT_MODE=uefi`
gives it an OVMF/UEFI firmware and `TPM=Y` gives it an emulated **TPM 2.0**, so the
install-time `%post` enrollment binds to PCR 7 and the reboot should auto-unlock with
no passphrase prompt — the same flow as real hardware. The install disk is ephemeral
(discarded on exit); the Anaconda/boot web console is at `http://localhost:8006`
(auto-opened). Build the ISO first with `just iso <flavor> local`.

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
      as needed. *(2026-07-21: first on-hardware attempt hit `liveinst`'s
      "kickstart is not supported on live iso installs" — fixed by the automated
      `anaconda.target` GRUB entry above; needs a re-test.)*
- [x] **Install automation** — Finnish locale/keyboard, Helsinki TZ, full-disk
      LUKS auto-partition; **both flavors zero-click** (student = baked `opilas`;
      staff = baked placeholder `staff` login, to be replaced by the USB
      provisioning config). *(code; needs the on-hardware validation above.)*
- [ ] **Validate TPM2 auto-unlock + on-screen recovery key** on real hardware
      (see "Install automation & disk encryption").
- [x] **Per-image branding** — done: student/staff stamp their own os-release via
      `/usr/libexec/svk/stamp-os-release`. `IMAGE_ID` reports `svk-student` /
      `svk-staff` (not `svk-base`) for tooling; `PRETTY_NAME` (what fastfetch and
      the Anaconda WebUI actually display) carries flavor + channel + version,
      e.g. `SVK OS (staff-stable-1-20260719)`.
- [ ] **LAN-mirror `flatpak update` wiring** (D7) — the client-side remote setup.
- [ ] Confirm the kiosk autologin (`opilas`, sysusers-locked) works post-install.
