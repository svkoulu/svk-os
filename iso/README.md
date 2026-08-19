# svk ISOs — Titanoboa (container-native ISO contract)

The installer ISO — **one ISO for the whole fleet** — is built with
[Titanoboa](https://github.com/ublue-os/titanoboa), the same tool Bazzite's live
ISOs use. Titanoboa is pinned to a specific commit
(`5c457c3d0518bd17e754be0fd98a60d29d26abb4`, 2026-05-19) — upstream did a breaking
rewrite around then (`feat!: Only use container images as the only source of
truth`, PR #138) that dropped its old Justfile/`HOOK_post_rootfs` interface
entirely. Titanoboa is now a thin tool: it just squashfs's a container image into
a boot-and-run LiveOS ISO, driven by an `/usr/lib/bootc-image-builder/iso.yaml`
baked **inside the image**. Anaconda, the kickstart, and the offline flatpak bake
are no longer something Titanoboa injects — they're baked into a throwaway
**installer image** (`iso/installer/`) built FROM the real `svk-os` image and fed to
Titanoboa. That installer image is never pushed anywhere; only the ISO
it produces matters. This is decision **D6** in the rebuild plan; it replaced the
old plain `bootc-image-builder` ISO workflow, and was itself later adapted when
Titanoboa's own interface changed upstream.

## Pieces

| File | Role |
|---|---|
| `flatpaks/common.list` | the fleet app set, baked into the ISO (system scope) |
| `iso/installer/Containerfile` | builds the throwaway installer image `FROM` the real `svk-os` image |
| `iso/installer/build.sh` | installs Anaconda (+`tmux`, needed by `anaconda.service`) and the on-site repair kit, writes **both role kickstarts** (localization + auto-partition + LUKS, `bootc switch`es the origin to the signed registry ref, rsyncs the baked `/var/lib/flatpak` onto the target — **no Secure Boot enrollment**, N4), pre-installs the flatpak set into `/var/lib/flatpak`, adds `dracut-live`/`livesys-scripts` for live-boot, and writes `iso.yaml` |
| `iso/build-iso.sh` | wrapper: get `svk-os` into local podman storage (and, for a local build, export it to `iso/.local-image/` for the installer's baked install payload), build the installer image, run pinned Titanoboa against it, collect the ISO — all **rootless** |
| `files/os/usr/libexec/svk/luks-tpm-enroll` (+ `.service`) | first-boot: TPM2 auto-unlock enrollment + on-screen per-machine recovery key (shipped in the OS image, not the ISO) |
| `files/os/usr/libexec/svk/tpm2-capable` | the TPM2 capability probe both the install-time `%post` and the first-boot service gate on (device **and** `PolicyAuthorizeNV`) |
| `.github/workflows/iso.yml` | the ISO build — reusable (called by `build.yml` per channel) and `workflow_dispatch` |

## `local` vs `ghcr`

`iso/build-iso.sh ghcr` builds an ISO around the published image; `... local`
builds one around whatever `just build-os` last produced. The distinction is
easy to get wrong, because two different images are involved:

- the **live environment** the ISO boots (the installer image, built `FROM` the
  target), and
- the **installed system**, which Anaconda deploys from a second copy of the image
  baked into that installer image (see below).

Building `FROM` an image gives you the first but not the second — same file
content, but none of the image's manifest/config, which is what Anaconda needs to
reconstruct an ostree deployment and record what the machine runs. So the
installer build has to put that copy there explicitly. Until 2026-08-19 it did so
with an unconditional `podman pull` of the ghcr ref, which meant **`local` did not
actually test local content**: the live environment was yours, the installed
system was ghcr's `:stable`, and while no `:stable` tag existed the build simply
failed. Now a local build exports the image to `iso/.local-image/image.tar`
(bind-mounted into the installer build, never a layer, deleted on exit) and bakes
it under the real registry ref, so the kickstart and the installed machine's
update origin stay identical to a production build.

Consequence worth knowing before you start one: a local ISO build writes the
image **twice** — the local build itself and the OCI archive — on top of a
multi-GB installer image and the squashfs/ISO output. (It was three before the
build went rootless; the root-storage copy is gone.)
Measured on 2026-08-19, x86_64, with the 16-app flatpak set:

| step | on-disk cost |
|---|---|
| `just build-os` | ~6.5 GB |
| OCI archive for the install payload (deleted on exit) | ~2.7 GB |
| installer image (Anaconda + flatpaks + the baked payload) | **~13 GB** |
| squashfs + ISO output | ~12-15 GB |
| the VM you then install into | ~10 GB |

The installer-image figure was ~17 GB when the payload was an unpacked
`containers-storage` tree; the layout keeps it compressed, so ~4 GB of that is
gone and the ~45 GB below is now the conservative end.

So **~45 GB free** is the realistic figure for build-and-test on one machine, and
a run that starts with less will die somewhere in the middle — a build killed
during `COMMIT` leaves the whole thing in a buildah working container that
`podman rm --storage` has to clear by hand.

## The install payload is a packed OCI layout

`iso/installer/build.sh` writes that second copy with `skopeo copy` into an **OCI
layout directory** at `/var/lib/svk/install-image`, and every kickstart installs
from it with `ostreecontainer --transport=oci`. A layout is just the layer
tarballs plus an `index.json`; nothing is unpacked until Anaconda writes it onto
the target disk.

Unpacking it into the installer image's own `containers-storage` instead does not
work, in two ways. Every deletion in the image becomes a real whiteout object on
disk, and nested podman — which cannot use the kernel overlay driver, its
graphroot being on the outer build's overlay rootfs — falls back to fuse-overlayfs,
which refuses to create any name starting with `.wh.`. And where it does succeed,
those objects still have to survive being committed as a layer of the installer
image, where an overlay-driver host reads them back as its own deletions and eats
them. Blobs have neither problem, on any host, rootless or not.

## Dependencies

Beyond the general build dependencies in the top-level `README.md`
(`podman`, `just`), building an ISO also needs:

| Tool | Used for |
|---|---|
| `git` | cloning the pinned Titanoboa commit |
| `rsync` | copying that clone into `iso/.build/` |

Install on Fedora: `sudo dnf install git rsync`.
On openSUSE Tumbleweed: `sudo zypper install git rsync`.

**No root, and no `sudo` anywhere in the build** (2026-08-19). It used to want
password-authenticated `sudo` for "root podman + Titanoboa's privileged
squashfs/loop-device work", and that turned out to be untrue of both halves: the
installer image is an ordinary `podman build` (`--cap-add sys_admin` is a
*namespaced* capability a rootless container may hold, and is there for the
flatpak bake), and Titanoboa's ISO step runs `mksquashfs -all-root`, `mkfs.fat` +
`mcopy` on a plain file, and `xorriso` — no loop device, no real uid, nothing
that a user namespace can't provide. `build-iso.sh` therefore patches upstream
`main.sh`'s single hard-coded `sudo podman run` out of its pinned local copy, and
**fails the build** if a `TITANOBOA_REF` bump ever leaves a `sudo` behind.

Two things this bought, beyond not typing a password:
- the multi-GB user→root image copy (`podman image scp`) is gone — one store, so
  the installer image built in step 2 is already where Titanoboa looks for it;
- it now works from inside a **distrobox/toolbox/devcontainer**. That was the old
  hard requirement to use a genuine host shell: unprivileged `podman` bridges out
  to the host fine, but `sudo podman` can't reach back into the bridge's D-Bus
  session and failed with `command not found` or an unprompted `a password is
  required`, no matter how correct the password was.

**Environment requirements**:
- A few GB of free disk headroom (`podman system df` / `podman system prune`
  to check/reclaim) — the installer image build and the squashfs/ISO output
  are each multi-GB.

## Build locally

```bash
# after svk-os is pushed (or built locally with :latest):
iso/build-iso.sh ghcr             # or: iso/build-iso.sh local
```

ISO lands at `iso/svk-os-<version>.iso`.

## Boot menu: the role is a menu choice

There is one image and one ISO; **which kind of machine you're building is decided
at the boot menu**, by picking which kickstart runs. All four entries boot the same
live filesystem:

| GRUB entry | What it does |
|---|---|
| **0 — `Install … - LAB machine (opilas kiosk)`** (default, 15s) | Boots `systemd.unit=anaconda.target` — the same code path a Fedora **boot.iso** uses — and hands Anaconda `svk-lab.ks`. Creates `opilas` (locked password, GDM autologin, kiosk dconf profile, `opilas` hidden-launcher set) + `admin`. Zero clicks: installs, then reboots. |
| **1 — `Install … - STAFF laptop`** | Same, with `svk-staff.ks`: creates `staff` (normal login, `svk-staff` group, password expired at first login, `wheel-only` hidden-launcher set) + `admin`. |
| **2/3 — `Live desktop …`** (plain / basic graphics) | The normal live GNOME session, fully featured, plus the on-site repair kit (`nmap`, `smartmontools`, `nvme-cli`, `ddrescue`, `testdisk`, `gparted`, `tcpdump`, `cryptsetup`, `tpm2-tools`, …). Installing from it via *Install to Hard Drive* works, but **interactively** and with **no role** — see below. |

Both install entries run under **`inst.cmdline`**, not `inst.text`: fully
non-interactive. If the kickstart ever fails to answer something, the install
**aborts with the unanswered question on the console** instead of parking at a
prompt that, on an unattended provisioning run, is indistinguishable from a slow
install.

> ⚠️ Entry 0 is the **default** and erases the target disk after a 15s
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

The live-desktop path gets **no role** — neither role's accounts nor its
`environment.d` files — so an interactively-installed machine is a plain `svk-os`
desktop and whoever the operator creates gets the unrestricted launcher set. It gets
`interactive-defaults.ks` populated with the
`ostreecontainer` line and the same `%post` steps. That is **not** cosmetic: an
empty `interactive-defaults.ks` makes Anaconda fall back to `LiveOSPayload`, which
would write the throwaway installer rootfs to disk as a plain, non-bootc system
that never updates. What it deliberately omits is the `%pre`-minted LUKS
passphrase, `autopart`, the account and `reboot` — the operator supplies those. A
machine installed this way therefore gets **no TPM enrollment** and prompts for the
operator's passphrase on every boot. It's a fallback for odd hardware, not the
fleet's provisioning route.

## Install automation & disk encryption

> **DISK ENCRYPTION IS OFF (bring-up, 2026-07-28).** Everything LUKS in
> `common_ks()` is commented out — installs are now **plain btrfs autopart**, and
> the "Disk encryption (LUKS + TPM2)" section below describes the state to
> restore, not the current one. The first hardware install (HP EliteBook 845 G7,
> fTPM 2.0, Secure Boot on) came up at an unanswerable passphrase prompt: the
> install-time TPM2 enrollment silently didn't happen (`luksDump`: one password
> keyslot, no `systemd-tpm2` token) and the only passphrase that could have opened
> the disk existed solely in the installer's RAM and on the encrypted disk itself.
> Re-enable only after a failed enrollment can no longer brick an install.

Both kickstarts pre-answer every Anaconda step, so either role installs with no
manual steps from its **automated** GRUB entry. They differ ONLY in the role
`%post` — same image, same everything else:

| | lab (`svk-lab.ks`) | staff (`svk-staff.ks`) |
|---|---|---|
| Manual steps | **none** — installs and reboots on its own | **none** — installs and reboots on its own |
| Accounts | `opilas` (uid 1000, locked password, GDM autologin) + `admin`; root locked | `staff` (regular user, no sudo, group `svk-staff`) + `admin`; root locked |
| Role `%post` | writes `/etc/gdm/custom.conf` (autologin) and `/etc/skel/…/20-svk-role.conf` (`DCONF_PROFILE=kiosk` + the `opilas` hidden-launcher set) | writes `/etc/skel/…/20-svk-role.conf` (the `wheel-only` hidden-launcher set) into skel **and** the staff home, then `chage -d 0 staff` |
| Language / keyboard | Finnish (`fi_FI.UTF-8`, `fi` layout) | same |
| Timezone | Europe/Helsinki | same |
| Disk | wipe all disks → btrfs autopart (LUKS **disabled**, see the note above) | same |

`opilas` is created **by the kickstart**, not by `sysusers.d` in the image: with one
image for the whole fleet, that has to be an install-time decision or every staff
laptop would grow a kiosk account too. Everything kiosk-shaped in the image gates on
that account existing, so it is simply inert on a staff laptop.

The staff account is still a **placeholder** — username `staff`, with a placeholder
password that the kickstart **expires immediately** (`chage -d 0`), so the teacher is
forced to set a real one at first login. Override it per build with
`STAFF_PASSWORD=… iso/build-iso.sh …`. This matters more than it used to: the
lab/staff boundary is now scoped to the *account*, not the machine, so a weak staff
password is a real hole rather than a cosmetic one. The proper fix is the per-site
**USB provisioning config**
(`tasks/todo/20260719-0110-usb-provisioning-config.md`), which removes the baked
password entirely rather than substituting a better one — **do not treat this as
closed.**

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

Both ends run the same capability probe first —
`/usr/libexec/svk/tpm2-capable`, shipped in the image and called by the kickstart
`%post` *and* the first-boot service. It checks for `/dev/tpmrm0` **and** for the
`PolicyAuthorizeNV` command (`tpm2_getcap`, command index `0x192`), which TPM 2.0
chips older than v1.38 lack: such a chip has a device node and still cannot hold a
systemd enrollment. Probing means an unenrollable machine is *named as such on the
console* instead of being discovered as a mystery passphrase prompt weeks later.
Ported from Aeon's `tik` installer.

**No-TPM machines.** When the probe says the TPM can never be enrolled, retrying is
pointless, so the first-boot service stops rather than prompting forever, and the
**recovery key becomes the every-boot secret** — the banner says so explicitly, and
reports Secure Boot state (worth enabling on a machine that can't seal its key to a
TPM). The per-install passphrase slot is wiped **only if someone pressed ENTER** to
acknowledge the key; on an unattended install it is deliberately kept, since wiping
it would leave a disk whose only secret nobody wrote down. The service logs the
exact `systemd-cryptenroll --wipe-slot=password` command to finish the job by hand.

If you need that per-install passphrase (e.g. the machine rebooted before the key
was recorded), capture it from the installer console **before the auto-reboot** —
switch to a VT with `Ctrl+Alt+F2` and run `cat /tmp/svk-luks-bootstrap` — or read it
from `/etc/svk/luks-bootstrap` on the running machine. The proper fix is the **USB
provisioning config** (`tasks/todo/20260719-0110-usb-provisioning-config.md`), which
will write the per-machine passphrase to the physically-controlled SVK-PROV USB
instead. On target hardware (TPM 2.0 standard), this path is not normally hit.

⚠️ **Not yet validated on hardware** — confirm a TPM machine auto-unlocks (test it in
a VM with an emulated TPM first: `just run-iso`, see below). If it still prompts
every boot despite a TPM, the initramfs isn't honouring `rd.luks.options`; the recovery
key always works meanwhile.

## Build metadata & provenance — where to find it

Every ISO carries its provenance in several places, from "readable without booting"
to "baked deep inside." When correlating a machine, an ISO, or a captured log bundle
with the exact source it came from, look here:

| File | Where it lives | Contains | How to read it |
|---|---|---|---|
| `iso/svk-os-<version>.build-info.json` | **Next to the ISO**, and in the CI artifact zip alongside it | roles, channel, image-ref, image-version, **packaged-image commit**, **iso/ scripts commit**, iso filename, build timestamp | open the file (no boot/unsquash needed) — the fast path |
| CI artifact name | GitHub Actions | `svk-os-<channel>-<shortsha>-iso` | the downloaded zip's name is self-identifying |
| `/usr/share/svk-os/iso-build-info.json` | Inside the ISO's **live/installer env** (the squashfs) | image-ref, roles, **iso/ scripts commit**, built-at | boot the installer and `cat` it, or `unsquashfs` `LiveOS/squashfs.img` |
| `/usr/share/svk-os/image-info.json` | Inside the **installed image** | image identity + **`git-commit`** of the packaged image | on a running machine, `cat` it |
| os-release `BUILD_ID` / `IMAGE_VERSION` | Inside the **installed image** | packaged-image commit / version string | `cat /etc/os-release` on a running machine |

The `.build-info.json` sidecar is the deliberate answer to "which commit is this
downloaded ISO?" — the deeper copies (squashfs, installed image) can only be read
after booting or unsquashing. The sidecar is produced by `iso/build-iso.sh` and
uploaded by `.github/workflows/iso.yml`; it is a build output (gitignored), **not**
a secret — the per-install LUKS passphrase is minted at install time and appears in
none of these files.

## Test the ISO in a VM (`just run-iso`)

`just run-iso` boots the newest locally-built `iso/svk-os-*.iso` in a
throwaway VM to exercise the whole install → reboot → first-boot path end-to-end,
**including LUKS + TPM auto-unlock**. It runs the [`qemux/qemu`](https://github.com/qemus/qemu)
container (needs `/dev/kvm` + `podman`, but **no host qemu or swtpm**): `BOOT_MODE=uefi`
gives it an OVMF/UEFI firmware and `TPM=Y` gives it an emulated **TPM 2.0**, so the
install-time `%post` enrollment binds to PCR 7 and the reboot should auto-unlock with
no passphrase prompt — the same flow as real hardware. The install disk is ephemeral
(discarded on exit); the Anaconda/boot web console is at `http://localhost:8006`
(auto-opened). Build the ISO first with `just iso local`, and pick the role in the
guest's own GRUB menu.

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
      LUKS auto-partition; **both roles zero-click** from their own GRUB entry
      (lab = `opilas`; staff = placeholder `staff` login with an expired password,
      to be replaced by the USB provisioning config). *(code; needs the on-hardware
      validation above.)*
- [ ] **Validate TPM2 auto-unlock + on-screen recovery key** on real hardware
      (see "Install automation & disk encryption").
- [x] **Image branding** — os-release is stamped via
      `/usr/libexec/svk/stamp-os-release`. `IMAGE_ID` reports `svk-os` for tooling;
      `PRETTY_NAME` (what fastfetch and the Anaconda WebUI actually display) carries
      channel + version, e.g. `SVK OS (stable-1-20260719)`.
- [ ] **LAN-mirror `flatpak update` wiring** (D7) — the client-side remote setup.
- [ ] Confirm the kiosk autologin (`opilas`, created **locked by the kickstart**)
      works post-install — GDM's autologin PAM stack doesn't check the password, but
      this moved from `sysusers.d` to the kickstart and needs a re-test.
- [ ] Confirm the role `%post` lands: on a lab install `DCONF_PROFILE=kiosk` must be
      in the session env **before** dconf is first read, and the prepended
      `XDG_DATA_DIRS` must actually hide the restricted launchers without hiding the
      flatpak apps (flatpak's own env generator runs after systemd's, and appends).
- [ ] Measure the ISO size after the six new flatpaks + two theme runtimes + the
      repair kit — LibreOffice, GIMP, Inkscape and Audacity are all large.
