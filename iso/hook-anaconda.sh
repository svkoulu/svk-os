#!/usr/bin/env bash
# hook-anaconda.sh — svk's Titanoboa `HOOK_post_rootfs` hook.
#
# Runs INSIDE the live-ISO rootfs while Titanoboa builds it. Its job: install and
# configure the Anaconda installer that ships on the ISO, and bake the offline
# flatpak set onto the target at install time. Adapted (slimmed) from
# projectbluefin/iso's iso_files/configure_iso_anaconda.sh.
#
# svk changes vs. upstream:
#   - image ref comes from $SVK_IMAGE_REF (passed by iso/build-iso.sh), NOT from
#     image-info.json (svk-student/-staff currently inherit svk-base's image-info,
#     see the branding TODO in the plan) — so the installer targets the right image.
#   - NO Secure Boot key enrollment (svk ships no custom kmods; N4=skip).
#   - NO Bluefin branding clone.
#   - bootc switch enforces svk's cosign signature policy on the installed origin.
#
# STATUS: written from the verified upstream but NOT yet validated by a real ISO
# build (needs AC power). Treat the Anaconda-plumbing sections as needing a first
# on-hardware build to confirm.
set -eoux pipefail

# The bootc image this ISO installs, e.g. ghcr.io/svkoulu/svk-student:stable.
: "${SVK_IMAGE_REF:?SVK_IMAGE_REF must be set (ghcr.io/svkoulu/svk-<flavor>:<tag>)}"
IMAGE_REF="${SVK_IMAGE_REF%%@*}"          # strip any digest
IMAGE_TAG="${IMAGE_REF##*:}"; [[ "$IMAGE_TAG" == "$IMAGE_REF" ]] && IMAGE_TAG="stable"
IMAGE_REF="${IMAGE_REF%%:*}"              # bare repo (no tag)

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
SPECS=(
    libblockdev-btrfs
    libblockdev-lvm
    libblockdev-dm
    anaconda-live
    firefox            # live-env browser only; not in the installed svk image
)
dnf install -y "${SPECS[@]}"

# Anaconda profile for svk (btrfs, hide the account spokes — student autologs into
# the baked opilas account; staff users are created by gnome-initial-setup at first
# boot). Matches our os-release VARIANT_ID=main.
mkdir -p /etc/anaconda/profile.d
tee /etc/anaconda/profile.d/svk.conf <<'EOF'
[Profile]
profile_id = svk

[Profile Detection]
os_id = fedora
variant_id = main

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
# enforcing svk's cosign policy. Then disable Fedora flatpaks and rsync the
# offline-baked flatpaks onto the target. NO Secure Boot enrollment.
tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=${IMAGE_REF}:${IMAGE_TAG} --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/svk-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/svk-disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/svk-install-flatpaks.ks
EOF

mkdir -p /usr/share/anaconda/post-scripts

# Re-point the update source to the signed registry ref.
tee /usr/share/anaconda/post-scripts/svk-configure-upgrade.ks <<EOF
%post --erroronfail
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry ${IMAGE_REF}:${IMAGE_TAG}
%end
EOF

# Never ship the Fedora flatpak remote.
tee /usr/share/anaconda/post-scripts/svk-disable-fedora-flatpak.ks <<'EOF'
%post --erroronfail
systemctl disable flatpak-add-fedora-repos.service 2>/dev/null || true
%end
EOF

# Bake the offline flatpaks: rsync the live ISO's (Titanoboa-populated)
# /var/lib/flatpak into the target deployment's /var/lib. This is the mechanism
# that makes first boot fully offline and puts the apps in system scope (so a
# student home-reset never loses them).
tee /usr/share/anaconda/post-scripts/svk-install-flatpaks.ks <<'EOF'
%post --erroronfail --nochroot
deployment="$(ostree rev-parse --repo=/mnt/sysimage/ostree/repo ostree/0/1/0)"
target="/mnt/sysimage/ostree/deploy/default/deploy/${deployment}.0/var/lib/"
mkdir -p "$target"
rsync -aAXUHKP /var/lib/flatpak "$target"
%end
EOF

echo "svk hook-anaconda.sh complete for ${IMAGE_REF}:${IMAGE_TAG}"
