#!/usr/bin/env bash
# iso/installer/build.sh — bakes Anaconda + the offline flatpak set + live-boot
# support into the throwaway installer image (see Containerfile in this dir).
#
# Runs INSIDE the installer image build (RUN'd from the Containerfile). Replaces
# svk's old iso/hook-anaconda.sh: upstream Titanoboa dropped its HOOK_post_rootfs
# mechanism and stopped shipping Anaconda entirely (container-native ISO contract
# v0.1.0 — see https://github.com/ondrejbudai/bootc-isos). Everything the ISO
# needs (installer, kickstart, pre-seeded flatpaks, dracut-live, iso.yaml) is now
# this image's own responsibility, same pattern ublue-os/bazzite uses in its
# installer/ directory.
#
# svk stays simple relative to bazzite's version: GNOME-only (no per-DE
# branching), no Secure Boot enrollment (N4 — no custom kmods on the raw
# Silverblue base), no multi-desktop/nvidia variants.
set -euxo pipefail

FLAVOR="${FLAVOR:?FLAVOR must be set (student|staff)}"
case "$FLAVOR" in student|staff) ;; *) echo "FLAVOR must be student|staff" >&2; exit 1 ;; esac

# The real registry ref the installed machine should track, e.g.
# ghcr.io/svkoulu/svk-student:stable — independent of what this installer image
# was built FROM (which may be a local dev tag). Baked into the kickstart's
# ostreecontainer + bootc switch targets.
: "${IMAGE_REF:?IMAGE_REF must be set (ghcr.io/svkoulu/svk-<flavor>:<tag>)}"
IMAGE_REPO="${IMAGE_REF%%:*}"
IMAGE_TAG="${IMAGE_REF##*:}"; [[ "$IMAGE_TAG" == "$IMAGE_REPO" ]] && IMAGE_TAG="stable"

# BASE_IMAGE's org.opencontainers.image.version (e.g. stable-1-20260719), read by
# iso/build-iso.sh before this build; blank for a local image with no version
# label. Same "SVK OS (<flavor>-<version>)" format as os-release PRETTY_NAME (see
# stamp-os-release) so the GRUB boot menu and the Anaconda WebUI agree.
VERSION="${VERSION:-}"
DISPLAY_NAME="SVK OS (${FLAVOR}${VERSION:+-${VERSION}})"

# NOTE: the LUKS encryption passphrase is NOT set here and is NOT baked into the
# ISO. It is generated per-install in the kickstart's %pre (see common_ks below), so
# every machine gets a unique, throwaway passphrase and no shared secret ever ships
# in the installer image. See files/base/usr/libexec/svk/luks-tpm-enroll for the
# first-boot enrollment/wipe, and iso/README.md for the full disk-encryption model.

# ISO9660 volume label — what shows up as the USB drive's name in a file manager
# once it's burned/dd'd, and what root=live:CDLABEL=${LABEL} below matches against
# to find the right device at boot. Level-1 caps this at 32 chars (svk-student-
# stable-<N>-<date> is 29 at N=1, room to spare).
LABEL="svk-${FLAVOR}${VERSION:+-${VERSION}}"

### Live-environment tweaks ####################################################
# Don't suspend during install / first-boot user creation.
tee /usr/share/glib-2.0/schemas/zz3-svk-installer-power.gschema.override <<'EOF'
[org.gnome.settings-daemon.plugins.power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0

[org.gnome.desktop.session]
idle-delay=uint32 0
EOF
glib-compile-schemas /usr/share/glib-2.0/schemas

# Services that should not run in the throwaway live environment.
for unit in rpm-ostree-countme.service tailscaled.service bootloader-update.service \
            rpm-ostreed-automatic.timer uupd.timer; do
    systemctl disable "$unit" 2>/dev/null || true
done

### Install Anaconda into the live ISO #########################################
#
# `tmux` is not optional: the automated boot entry runs Anaconda under
# anaconda.target, whose anaconda.service is literally `tmux -f
# /usr/share/anaconda/tmux.conf start` (that tmux.conf is what spawns `anaconda`,
# plus the log-tail windows). anaconda-direct.service doesn't get you out of it —
# it `Requires=anaconda.service` too. Silverblue doesn't ship tmux, so without
# this the automated entry dies at "anaconda.service: Failed to execute command".
dnf5 install -y \
    libblockdev-btrfs \
    libblockdev-lvm \
    libblockdev-dm \
    anaconda-live \
    tmux \
    firefox            # live-env browser only; not in the installed svk image

mkdir -p /var/lib/rpm-state # needed for Anaconda's WebUI front-end

# Anaconda profile for svk. Matches our os-release VARIANT_ID=silverblue (svk-base
# is raw Silverblue, not FROM bluefin, so it never gets bluefin's VARIANT_ID=main —
# confirmed by inspecting a built image; the old hook-anaconda.sh's "variant_id =
# main" was never validated and was simply wrong, so Anaconda fell back to a
# different, non-svk profile).
#
# No hidden_spokes/hidden_webui_pages here: the WebUI ignores the old GTK spoke
# names (that's why a hidden UserSpoke still showed the account page), and the
# modern anaconda-screen-* page ids are Fedora-version-fragile. Instead the
# complete kickstart below *pre-satisfies* every step (locale/keyboard/timezone/
# storage/encryption/account) for BOTH flavors, so nothing prompts at all — staff
# now bakes its login account too (see the case block), rather than stopping at the
# Create Account page.
mkdir -p /etc/anaconda/profile.d
tee /etc/anaconda/profile.d/svk.conf <<'EOF'
[Profile]
profile_id = svk

[Profile Detection]
os_id = fedora
variant_id = silverblue

[Network]
default_on_boot = FIRST_WIRED_WITH_LINK

[Bootloader]
efi_dir = fedora
menu_auto_hide = True

[Storage]
default_scheme = BTRFS
btrfs_compression = zstd:1

[Localization]
use_geolocation = False
EOF

### Populate this image's own containers-storage with the install target #######
# `ostreecontainer --transport=containers-storage` (below) installs from a copy
# already sitting in local container storage — no network needed at install
# time. That copy has to be put there at BUILD time: building `FROM` the target
# image only gives this installer image the same filesystem content, not a
# separate, discretely-tagged image entry for Anaconda to find. Nested podman
# (enabled by --cap-add sys_admin on the outer `podman build`) pulls it in.
# Requires the ref to already be published and pullable (ghcr packages public,
# or credentials available) — matches Bazzite's installer/build.sh pattern.
#
# The nested pull inherits THIS filesystem's own strict /etc/containers/policy.json
# (cosign-signed-only for ghcr.io/svkoulu), which rejects it — sigstore-attachment
# discovery doesn't verify the same way from inside a nested build. Swap in a
# permissive policy just for this internal fetch: the kickstart's own install step
# already does `--no-signature-verification` explicitly, and the INSTALLED system's
# real policy.json comes from the deployed svk-staff content itself, not from
# anything in this throwaway installer image, so this has no effect on the fleet's
# actual signature enforcement.
cp /etc/containers/policy.json /tmp/svk-policy.json
echo '{"default":[{"type":"insecureAcceptAnything"}]}' > /etc/containers/policy.json
# Always a fresh, direct pull — no reuse-from-host-storage shortcut. A prior
# `save | load --storage-opt additionalimagestore=''` version of this reload,
# from a read-only bind-mounted additional store, produced an image with a
# layer missing from storage ("layer not known" from `ostree container image
# deploy` at install time — confirmed via packaging.log from a real install).
# A plain pull reliably writes every layer into primary storage itself.
podman pull "${IMAGE_REPO}:${IMAGE_TAG}"
mv /tmp/svk-policy.json /etc/containers/policy.json

### Kickstart #################################################################
# The kickstart pre-satisfies every Anaconda step so nothing prompts: Finnish
# locale + keyboard, Helsinki timezone, and full-disk btrfs with LUKS encryption
# (TPM2 auto-unlock is enrolled at first boot — see luks-tpm-enroll in the base
# image). It installs the svk image from the ISO's own containers-storage, then
# re-points the bootc origin at the signed registry ref so the machine auto-updates
# from ghcr enforcing svk's cosign policy; disables Fedora flatpaks; rsyncs the
# offline-baked flatpaks onto the target; and fixes their SELinux labels. NO Secure
# Boot enrollment.
#
#   student — fully unattended: complete kickstart (baked opilas account, locked
#             root, reboot) delivered via inst.kickstart= on the boot cmdline of
#             the automated GRUB entry (iso.yaml).
#   staff   — fully unattended too: complete kickstart with a baked `staff` login
#             (placeholder password, regular user — no sudo; admin handles that over
#             SSH). This is the validation step that proves the account step can be
#             fully automated with NO Create Account page; the per-site USB
#             provisioning config (tasks/todo/20260719-0110-usb-provisioning-config.md)
#             replaces this placeholder later.
mkdir -p /usr/share/anaconda/post-scripts

# Directives shared by both flavors. `clearpart --all` + `autopart` remove the disk
# prompt. The LUKS passphrase is generated per-install in %pre (no shared secret in
# the ISO) and consumed via the %include'd storage line. `--noswap`: rely on zram.
common_ks() {
# First heredoc is single-quoted: the %pre script's $pass / $(...) MUST reach the
# kickstart verbatim and run at INSTALL time, not be expanded now by this build.
cat <<'EOF'
# Localization — Finnish language + keyboard, Helsinki time.
lang fi_FI.UTF-8
keyboard --vckeymap=fi --xlayouts=fi
timezone Europe/Helsinki --utc

# Full disk, btrfs, LUKS. The encryption passphrase is generated per-install in the
# %pre below (nothing baked into the ISO) and pulled in via %include. TPM2 is
# pre-enrolled at install time (svk-luks-tpm.ks %post) so the FIRST boot auto-unlocks
# with no prompt; the kernel arg tells the initramfs to try the TPM first.
zerombr
clearpart --all --initlabel
%include /tmp/svk-storage.ks
bootloader --append="rd.luks.options=tpm2-device=auto"

# Per-install LUKS passphrase: unique to THIS machine, minted here at install time so
# no shared secret ever lives in the ISO/installer image. Alnum-only (32 chars from
# /dev/urandom) to sidestep any kickstart quoting edge cases. Written into the
# autopart %include consumed above, and stashed at /tmp/svk-luks-bootstrap for the
# %post that seeds the target's /etc/svk/luks-bootstrap. On a machine with NO TPM
# (where first boot would prompt for it), an attended operator can read it before the
# auto-reboot via a console (Ctrl+Alt+F2): `cat /tmp/svk-luks-bootstrap`.
%pre --erroronfail
umask 077
pass="$(head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
printf '%s\n' "$pass" > /tmp/svk-luks-bootstrap
printf 'autopart --type=btrfs --noswap --encrypted --passphrase="%s"\n' "$pass" \
    > /tmp/svk-storage.ks
%end
EOF
# Second heredoc is unquoted so ${IMAGE_REPO}:${IMAGE_TAG} expand at build time.
cat <<EOF

ostreecontainer --url=${IMAGE_REPO}:${IMAGE_TAG} --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/svk-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/svk-disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/svk-install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/svk-flatpak-selinux.ks
%include /usr/share/anaconda/post-scripts/svk-luks-bootstrap.ks
%include /usr/share/anaconda/post-scripts/svk-luks-tpm.ks
EOF
}

case "$FLAVOR" in
student)
    # Complete, non-interactive kickstart: no account page (opilas is baked into the
    # image via sysusers.d), root locked, auto-reboot when done. Referenced by
    # the automated entry's inst.kickstart= in iso.yaml, so Anaconda runs it
    # start-to-finish with no clicks.
    { common_ks; cat <<'EOF'
rootpw --lock
firstboot --disable
reboot
EOF
    } > /usr/share/anaconda/svk-student.ks
    ;;
staff)
    # Complete, non-interactive kickstart too — no Create Account page. Bakes a
    # `staff` login as a REGULAR user (no --groups=wheel: local sudo is intentionally
    # admin-only, over SSH). The password is a deliberate placeholder — `stafff`, 6
    # chars to clear Anaconda's default `pwpolicy user --minlen=6` — that lets us
    # confirm end-to-end that staff can install with zero manual steps. The per-site
    # USB provisioning config replaces this with the real account(s) later; when it
    # lands, its %pre-generated `user` line supersedes this one.
    { common_ks; cat <<'EOF'
user --name=staff --gecos="Staff" --password=stafff --plaintext
rootpw --lock
firstboot --disable
reboot
EOF
    } > /usr/share/anaconda/svk-staff.ks
    ;;
esac

# The live-desktop GRUB entries carry no kickstart at all, so if the operator
# installs from the live session ("Install to Hard Drive" -> liveinst -> `anaconda
# --liveinst`), Anaconda reads exactly one kickstart: interactive-defaults.ks. It
# ships EMPTY, and an empty one is not harmless here — with no `ostreecontainer`
# the payload falls back to LiveOSPayload, which would dump the throwaway installer
# rootfs onto the disk as a plain, non-bootc system that never updates. So give
# that path the payload + the same %post steps, and let the UI collect
# language/disk/account.
#
# Deliberately NOT included: the %pre-minted LUKS passphrase and autopart/user/
# reboot — those are the operator's choices in this path. A machine installed this
# way is encrypted with the passphrase the operator typed and gets NO TPM
# enrollment (see the guard in svk-luks-bootstrap.ks), so it prompts for that
# passphrase on every boot. This path is a fallback for odd hardware, not the
# fleet's provisioning route.
cat >/usr/share/anaconda/interactive-defaults.ks <<EOF
# svk defaults for an INTERACTIVE install from the live desktop session.
# The unattended route is the automated GRUB entry -> svk-${FLAVOR}.ks.
lang fi_FI.UTF-8
keyboard --vckeymap=fi --xlayouts=fi
timezone Europe/Helsinki --utc

ostreecontainer --url=${IMAGE_REPO}:${IMAGE_TAG} --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/svk-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/svk-disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/svk-install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/svk-flatpak-selinux.ks
%include /usr/share/anaconda/post-scripts/svk-luks-bootstrap.ks
%include /usr/share/anaconda/post-scripts/svk-luks-tpm.ks
EOF

# Re-point the update source to the signed registry ref.
tee /usr/share/anaconda/post-scripts/svk-configure-upgrade.ks <<EOF
%post --erroronfail
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry ${IMAGE_REPO}:${IMAGE_TAG}
%end
EOF

# Never ship the Fedora flatpak remote.
tee /usr/share/anaconda/post-scripts/svk-disable-fedora-flatpak.ks <<'EOF'
%post --erroronfail
systemctl disable flatpak-add-fedora-repos.service 2>/dev/null || true
%end
EOF

# Bake the offline flatpaks: rsync this installer image's own (pre-populated
# below) /var/lib/flatpak into the target deployment's /var/lib. This is the
# mechanism that makes first boot fully offline and puts the apps in system
# scope (so a student home-reset never loses them).
tee /usr/share/anaconda/post-scripts/svk-install-flatpaks.ks <<'EOF'
%post --erroronfail --nochroot
deployment="$(ostree rev-parse --repo=/mnt/sysimage/ostree/repo ostree/0/1/0)"
target="/mnt/sysimage/ostree/deploy/default/deploy/${deployment}.0/var/lib/"
mkdir -p "$target"
rsync -aAXUHKP --open-noatime /var/lib/flatpak "$target"
sync "$target"
%end
EOF

# Fix SELinux labels on the rsync'd flatpaks (rsync --nochroot doesn't relabel).
tee /usr/share/anaconda/post-scripts/svk-flatpak-selinux.ks <<'EOF'
%post --erroronfail
chcon -R -t var_lib_t /var/lib/flatpak
%end
EOF

# Seed the target with THIS machine's per-install LUKS passphrase (minted in %pre).
# Runs --nochroot so it can read the passphrase from the installer runtime's /tmp and
# write it into the target under /mnt/sysimage. The first-boot service
# (files/base/usr/libexec/svk/luks-tpm-enroll) consumes it to enroll the TPM +
# per-machine recovery key, then WIPES the slot and deletes the file — so it never
# unlocks anything on the running fleet, and no shared secret was ever in the ISO.
#
# The `-f` guard is what lets this same script be shared with interactive-defaults.ks
# (the live-desktop install path), where there is no %pre and therefore no minted
# passphrase — without it, --erroronfail would abort that install outright.
tee /usr/share/anaconda/post-scripts/svk-luks-bootstrap.ks <<'EOF'
%post --erroronfail --nochroot
umask 077
if [ -f /tmp/svk-luks-bootstrap ]; then
    install -d -m 0700 /mnt/sysimage/etc/svk
    install -m 0600 /tmp/svk-luks-bootstrap /mnt/sysimage/etc/svk/luks-bootstrap
else
    echo "svk: no install-time LUKS passphrase (interactive install); skipping TPM bootstrap."
fi
%end
EOF

# Pre-enroll the TPM2 in the chroot so the FIRST boot auto-unlocks (no passphrase
# prompt). Reads the per-install passphrase from the file the previous %post wrote, so
# nothing has to be quoted/escaped here. Best-effort: a machine with no TPM (or a
# failed enrollment) falls back to the first-boot service, which enrolls a per-machine
# recovery key — the operator captures the one-time passphrase from the installer
# console (see %pre note) to get that first boot to run. PCR 7 (secure-boot state) is
# identical in the installer and the installed system on the same machine; PCRs 4/8/9
# are NOT, so bind only PCR 7.
tee /usr/share/anaconda/post-scripts/svk-luks-tpm.ks <<'EOF'
%post --erroronfail
if { [ -e /dev/tpmrm0 ] || [ -e /dev/tpm0 ]; } && [ -f /etc/svk/luks-bootstrap ]; then
    _uuid="$(awk '!/^#/ && NF {print $2; exit}' /etc/crypttab | sed 's/^UUID=//')"
    _dev="/dev/disk/by-uuid/${_uuid}"
    if [ -n "$_uuid" ] && [ -e "$_dev" ]; then
        PASSWORD="$(cat /etc/svk/luks-bootstrap)" \
            systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$_dev" \
            || echo "svk: install-time TPM2 enrollment failed; first boot will retry."
    fi
fi
%end
EOF

### Bake the offline flatpak set into THIS image ###############################
curl --retry 3 -Lo /etc/flatpak/remotes.d/flathub.flatpakrepo https://dl.flathub.org/repo/flathub.flatpakrepo
cat /tmp/flatpaks/common.list "/tmp/flatpaks/${FLAVOR}.list" \
    | sed 's/#.*//' | tr -d '[:blank:]' | grep -v '^$' | sort -u \
    | xargs -r flatpak install -y --noninteractive --system flathub

### Live-boot support (dracut-live: dmsquash-live mounts the squashfs at boot) ##
dnf5 install -y dracut-live
kernel="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | head -1)"
DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}"

### Live session (GNOME auto-login so there's a desktop to launch Anaconda from) #
dnf5 install -y livesys-scripts
sed -i "s/^livesys_session=.*/livesys_session=gnome/" /etc/sysconfig/livesys
systemctl enable livesys.service livesys-late.service

### EFI directory (container-native contract expects /boot/efi/EFI/$VENDOR) ####
dnf5 install -y grub2-efi-x64-cdboot
mkdir -p /boot/efi
cp -av /usr/lib/efi/*/*/EFI /boot/efi/

### Live-root runtime mounts ####################################################
# ostree needs real /var/tmp space; the live root's overlayfs-backed /var/tmp
# otherwise lives under the small tmpfs at /run.
tee /etc/systemd/system/var-tmp.mount <<'EOF'
[Unit]
Description=Larger tmpfs for /var/tmp on the live system

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=50%,nr_inodes=1m

[Install]
WantedBy=local-fs.target
EOF
systemctl enable var-tmp.mount

# Keep the baked flatpaks read-only while live, so they can't get corrupted
# before the install-time rsync copies them onto the target.
tee /etc/systemd/system/var-lib-flatpak.mount <<'EOF'
[Mount]
Type=none
What=/var/lib/flatpak
Where=/var/lib/flatpak
Options=bind,ro

[Install]
# Both boot paths: multi-user.target for the live desktop entry, anaconda.target
# for the automated one (which never reaches multi-user.target).
WantedBy=multi-user.target anaconda.target
EOF
systemctl enable var-lib-flatpak.mount

### Titanoboa contract: /usr/lib/bootc-image-builder/iso.yaml ##################
# One squashfs, two boot paths:
#
#   entry 0 (default) — AUTOMATED. Boots `systemd.unit=anaconda.target`, i.e. the
#     same code path a Fedora boot.iso uses, and hands Anaconda the complete
#     kickstart. Zero clicks: installs and reboots on its own.
#   entries 1-2 — the live GNOME desktop, unchanged and fully featured (browser,
#     terminal, disk tools). The operator can still install from it via GNOME's
#     "Install to Hard Drive", interactively.
#
# Why the automated entry can NOT just be the live session plus `inst.ks=`, which
# is what this file used to do:
#
#   1. /usr/bin/liveinst (anaconda-live) greps /proc/cmdline for `inst.ks=`, pops
#      "Kickstart is not supported on Live ISO installs [...] this installation
#      will continue interactively", and then DROPS it — it always execs the fixed
#      `anaconda --liveinst --graphical`.
#   2. Even handed the file, Anaconda would ignore it: startup_utils.find_kickstart
#      is gated `if options.ksfile and not options.liveinst`, so under --liveinst
#      the ONLY kickstart it will read is interactive-defaults.ks.
#
# So the automated path must avoid --liveinst entirely, which is exactly what
# booting anaconda.target does (anaconda.service -> tmux.conf -> bare `anaconda`,
# no flags — every option below therefore has to come from the boot cmdline).
#
# `inst.kickstart=<path>`, not `inst.ks=`: Anaconda's `--ks` is a store_const that
# always resolves to /run/install/ks.cfg (normally fetched by the dracut anaconda
# module, which this live initramfs doesn't include) — the value after `inst.ks=`
# is parsed and thrown away. `--kickstart` is the variant that takes a path, and
# it wants a plain path, not a file:// URL (it's fed to os.path.exists()).
#
# `inst.text`: run the TUI. A complete kickstart needs no UI, and this keeps the
# automated path from depending on a Wayland compositor (the live image has no
# gnome-kiosk). Progress prints to the console — hence no `quiet rhgb` here.
AUTO_ARGS="systemd.unit=anaconda.target inst.text"
AUTO_ARGS="${AUTO_ARGS} inst.kickstart=/usr/share/anaconda/svk-${FLAVOR}.ks"

mkdir -p /usr/lib/bootc-image-builder
tee /usr/lib/bootc-image-builder/iso.yaml <<EOF
label: "${LABEL}"
grub2:
  timeout: 15
  default: 0
  entries:
    - name: "Install ${DISPLAY_NAME} - automated, ERASES THE DISK"
      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=${LABEL} enforcing=0 rd.live.image ${AUTO_ARGS}"
      initrd: "/images/pxeboot/initrd.img"
    - name: "Live desktop - ${DISPLAY_NAME}"
      linux: "/images/pxeboot/vmlinuz quiet rhgb root=live:CDLABEL=${LABEL} enforcing=0 rd.live.image"
      initrd: "/images/pxeboot/initrd.img"
    - name: "Live desktop - ${DISPLAY_NAME} (Basic Graphics Mode)"
      linux: "/images/pxeboot/vmlinuz quiet rhgb root=live:CDLABEL=${LABEL} enforcing=0 rd.live.image nomodeset"
      initrd: "/images/pxeboot/initrd.img"
EOF

### ISO build provenance ########################################################
# Records which iso/ commit assembled THIS ISO/installer environment — separate
# from the packaged image's own git-commit (in its baked-in svk-os/image-info.json),
# since an ISO can be rebuilt with newer iso/ scripts against an older, already-
# published image. Lives only in the live/installer environment, never rsynced to
# the target — it's metadata about the ISO build, not the installed OS. Exactly the
# kind of thing worth having on hand if a captured log bundle needs correlating with
# the iso/ script version that produced it.
mkdir -p /usr/share/svk-os
cat >/usr/share/svk-os/iso-build-info.json <<EOF
{
  "flavor": "${FLAVOR}",
  "image-ref": "${IMAGE_REPO}:${IMAGE_TAG}",
  "iso-git-commit": "${ISO_GIT_SHA:-}",
  "built-at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

dnf5 clean all

echo "svk installer build.sh complete for ${IMAGE_REPO}:${IMAGE_TAG} (${FLAVOR}), iso-git-commit=${ISO_GIT_SHA:-<none>}"
