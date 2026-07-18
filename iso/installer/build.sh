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

LABEL="SVK-$(tr '[:lower:]' '[:upper:]' <<<"${FLAVOR:0:1}")${FLAVOR:1}-Live"

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
dnf5 install -y \
    libblockdev-btrfs \
    libblockdev-lvm \
    libblockdev-dm \
    anaconda-live \
    firefox            # live-env browser only; not in the installed svk image

mkdir -p /var/lib/rpm-state # needed for Anaconda's WebUI front-end

# Anaconda profile for svk (btrfs, hide the account spokes — student autologs into
# the baked opilas account; staff users are created by gnome-initial-setup at first
# boot). Matches our os-release VARIANT_ID=silverblue (svk-base is raw Silverblue,
# not FROM bluefin, so it never gets bluefin's VARIANT_ID=main — confirmed by
# inspecting a built image; the old hook-anaconda.sh's "variant_id = main" was
# never validated and was simply wrong, so Anaconda fell back to a different,
# non-svk profile).
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

[User Interface]
hidden_spokes =
    PasswordSpoke
    UserSpoke

[Localization]
use_geolocation = False
EOF

### Interactive kickstart ######################################################
# Install the svk image (from the ISO's own containers-storage), then re-point the
# bootc origin at the signed registry ref so the machine auto-updates from ghcr,
# enforcing svk's cosign policy. Then disable Fedora flatpaks, rsync the
# offline-baked flatpaks (installed into THIS image below) onto the target, and
# fix their SELinux labels. NO Secure Boot enrollment.
tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=${IMAGE_REPO}:${IMAGE_TAG} --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/svk-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/svk-disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/svk-install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/svk-flatpak-selinux.ks
EOF

mkdir -p /usr/share/anaconda/post-scripts

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
WantedBy=multi-user.target
EOF
systemctl enable var-lib-flatpak.mount

### Titanoboa contract: /usr/lib/bootc-image-builder/iso.yaml ##################
mkdir -p /usr/lib/bootc-image-builder
tee /usr/lib/bootc-image-builder/iso.yaml <<EOF
label: "${LABEL}"
grub2:
  timeout: 10
  default: 0
  entries:
    - name: "Install SVK ${FLAVOR^}"
      linux: "/images/pxeboot/vmlinuz quiet rhgb root=live:CDLABEL=${LABEL} enforcing=0 rd.live.image"
      initrd: "/images/pxeboot/initrd.img"
    - name: "Install SVK ${FLAVOR^} (Basic Graphics Mode)"
      linux: "/images/pxeboot/vmlinuz quiet rhgb root=live:CDLABEL=${LABEL} enforcing=0 rd.live.image nomodeset"
      initrd: "/images/pxeboot/initrd.img"
EOF

dnf5 clean all

echo "svk installer build.sh complete for ${IMAGE_REPO}:${IMAGE_TAG} (${FLAVOR})"
