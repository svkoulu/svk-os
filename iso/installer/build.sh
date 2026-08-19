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

# ONE ISO, TWO ROLES. There is no per-flavor image any more (svk-student and
# svk-staff collapsed into svk-os), so this ISO bakes BOTH kickstarts and the
# operator picks a role from the GRUB menu at boot:
#
#   svk-lab.ks    -> lab machine:   opilas (kiosk, autologin) + admin
#   svk-staff.ks  -> staff laptop:  staff  (normal login)     + admin
#
# The kickstart is what decides which accounts exist, which is the whole basis of
# the single-image collapse: the lockdown is scoped to the opilas ACCOUNT, so it
# ships in every image and is inert wherever that account was never created.
# See tasks/done/…-single-image-collapse.md.

# The real registry ref the installed machine should track, e.g.
# ghcr.io/svkoulu/svk-os:stable — independent of what this installer image was
# built FROM (which may be a local dev tag). Baked into the kickstart's
# ostreecontainer + bootc switch targets.
: "${IMAGE_REF:?IMAGE_REF must be set (ghcr.io/svkoulu/svk-os:<tag>)}"
IMAGE_REPO="${IMAGE_REF%%:*}"
IMAGE_TAG="${IMAGE_REF##*:}"; [[ "$IMAGE_TAG" == "$IMAGE_REPO" ]] && IMAGE_TAG="stable"

# Placeholder password for the baked `staff` login. INTERIM — the real fix is the
# per-site USB provisioning config, which generates the real accounts and removes
# the baked password entirely (tasks/todo/20260719-0110-usb-provisioning-config.md).
# Until then two things keep it honest: it is overridable per build
# (STAFF_PASSWORD=… iso/build-iso.sh …), and the kickstart expires it immediately
# so the teacher MUST set a real one at first login. With the lab/staff boundary
# now account-scoped rather than machine-scoped, this password is load-bearing —
# do not treat a better default as closing the issue.
STAFF_PASSWORD="${STAFF_PASSWORD:-svk-vaihda-tama}"

# BASE_IMAGE's org.opencontainers.image.version (e.g. stable-1-20260719), read by
# iso/build-iso.sh before this build; blank for a local image with no version
# label. Same "SVK OS (<version>)" format as os-release PRETTY_NAME (see
# stamp-os-release) so the GRUB boot menu and the Anaconda WebUI agree.
VERSION="${VERSION:-}"
DISPLAY_NAME="SVK OS${VERSION:+ (${VERSION})}"

# NOTE: the LUKS encryption passphrase is NOT set here and is NOT baked into the
# ISO. It is generated per-install in the kickstart's %pre (see common_ks below), so
# every machine gets a unique, throwaway passphrase and no shared secret ever ships
# in the installer image. See files/os/usr/libexec/svk/luks-tpm-enroll for the
# first-boot enrollment/wipe, and iso/README.md for the full disk-encryption model.

# ISO9660 volume label — what shows up as the USB drive's name in a file manager
# once it's burned/dd'd, and what root=live:CDLABEL=${LABEL} below matches against
# to find the right device at boot. Level-1 caps this at 32 chars (svk-os-stable-
# <N>-<date> is 24 at N=1, room to spare).
LABEL="svk-os${VERSION:+-${VERSION}}"

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

# On-site repair kit. The live ISO is the only environment a technician has when
# a machine won't boot — and, being throwaway, it's the one place where adding
# tools costs nothing but ISO size. tpm2-tools in particular is what lets someone
# diagnose a failed LUKS/TPM enrollment on the machine itself rather than by
# guessing. (`gdu` is not packaged in Fedora; `ncdu` is.)
dnf5 install -y \
    nmap ncdu bat vim ripgrep jq whois traceroute \
    smartmontools nvme-cli ddrescue testdisk gparted \
    hwinfo pciutils usbutils ethtool tcpdump \
    efibootmgr cryptsetup btrfs-progs tpm2-tools

mkdir -p /var/lib/rpm-state # needed for Anaconda's WebUI front-end

# Anaconda profile for svk. Matches our os-release VARIANT_ID=silverblue (svk-os
# is raw Silverblue, not FROM bluefin, so it never gets bluefin's VARIANT_ID=main —
# confirmed by inspecting a built image; the old hook-anaconda.sh's "variant_id =
# main" was never validated and was simply wrong, so Anaconda fell back to a
# different, non-svk profile).
#
# No hidden_spokes/hidden_webui_pages here: the WebUI ignores the old GTK spoke
# names (that's why a hidden UserSpoke still showed the account page), and the
# modern anaconda-screen-* page ids are Fedora-version-fragile. Instead both
# kickstarts below *pre-satisfy* every step (locale/keyboard/timezone/storage/
# encryption/account), so nothing prompts at all.
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

### Install payload: svk-os as an OCI layout ###################################
# The kickstarts install from this copy, which is what makes the install offline.
# Building FROM the target image is not enough: it gives this image the same file
# content, but none of the manifest/config Anaconda needs to reconstruct an ostree
# deployment.
#
# The copy stays packed — a layout is layer tarballs plus an index.json, ordinary
# files. Unpacking it here into a containers-storage tree cannot work: every
# deletion in the image becomes a real whiteout object, which fuse-overlayfs (what
# nested podman falls back to) refuses to create, and which an overlay-driver host
# eats when committing this image's layer.
#
# A layout DIRECTORY, not an oci-archive: an archive is extracted to /var/tmp
# before it can be read, and at install time that is the live environment's, a few
# GB inside a squashfs.
command -v skopeo >/dev/null 2>&1 || dnf5 install -y skopeo

# Every ostreecontainer --url below is built from this, so the path cannot drift.
INSTALL_IMAGE_DIR="/var/lib/svk/install-image"
mkdir -p "$INSTALL_IMAGE_DIR"

# This filesystem's policy.json requires a cosign signature for ghcr.io/svkoulu,
# which doesn't verify from inside a build. Swap it out for the copy only: the
# kickstart passes --no-signature-verification anyway, and the installed system's
# policy comes from the deployed image, not from this throwaway one.
cp /etc/containers/policy.json /tmp/svk-policy.json
echo '{"default":[{"type":"insecureAcceptAnything"}]}' > /etc/containers/policy.json
# A local build has the image bind-mounted in as an archive instead (iso/build-iso.sh);
# both branches land under the same tag, so the installed origin is identical.
if [ -f /tmp/local-image/image.tar ]; then
    echo "svk installer: baking the locally-built image instead of ${IMAGE_REPO}:${IMAGE_TAG}"
    TMPDIR=/var/tmp skopeo copy \
        "oci-archive:/tmp/local-image/image.tar" "oci:${INSTALL_IMAGE_DIR}:${IMAGE_TAG}"
else
    skopeo copy "docker://${IMAGE_REPO}:${IMAGE_TAG}" "oci:${INSTALL_IMAGE_DIR}:${IMAGE_TAG}"
fi
mv /tmp/svk-policy.json /etc/containers/policy.json
# Read it back the way the kickstart will ask for it: a layout that only fails at
# install time fails on a lab machine.
skopeo inspect --raw "oci:${INSTALL_IMAGE_DIR}:${IMAGE_TAG}" >/dev/null

### Kickstarts ################################################################
# Both kickstarts pre-satisfy every Anaconda step so nothing prompts: Finnish
# locale + keyboard, Helsinki timezone, and full-disk btrfs with LUKS encryption
# (TPM2 auto-unlock is enrolled at first boot — see luks-tpm-enroll in the image).
# They install svk-os from the OCI layout baked into this image, then re-point the
# bootc origin at the signed registry ref so the machine auto-updates from ghcr
# enforcing svk's cosign policy; disable Fedora flatpaks; rsync the offline-baked
# flatpaks onto the target; and fix their SELinux labels. NO Secure Boot enrollment.
#
# They differ ONLY in the role %post: which accounts exist, and which per-account
# environment.d files get planted. Same image either way.
#
#   svk-lab.ks   — lab machine:  opilas (locked password, GDM autologin, kiosk
#                  dconf profile + the `opilas` hidden-launcher set) + admin.
#   svk-staff.ks — staff laptop: `staff` (regular user, no sudo — admin handles
#                  that over SSH; member of svk-staff for gnome-software and
#                  system-scope flatpak installs; password expired on first login)
#                  + admin.
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

# Full disk, btrfs. `--noswap`: rely on zram.
#
# ENCRYPTION IS DISABLED FOR BRING-UP (2026-07-28) — everything LUKS is commented
# out below, restore it by swapping the plain `autopart` line for the %include +
# bootloader + %pre block and un-commenting the two %include's further down.
#
# Why: on the first real install (HP EliteBook 845 G7, fTPM 2.0, Secure Boot on)
# the install-time enrollment in svk-luks-tpm.ks did not happen — `luksDump` on
# the installed disk showed one password keyslot and NO systemd-tpm2 token — so
# the machine rebooted into a passphrase prompt. And because the passphrase is
# minted in %pre and only ever exists in the installer's RAM and on the encrypted
# disk itself, that prompt was unanswerable: the install was unrecoverable.
#
# Two things must be fixed before this comes back, in this order:
#   1. A failed enrollment must not brick the install (show the passphrase, or
#      halt instead of rebooting), and the reason must land somewhere readable
#      without unlocking the disk — the ESP.
#   2. Then find out WHY the chroot %post skipped: probe result, /dev/tpmrm0
#      visibility in the chroot, /etc/crypttab presence, or cryptenroll itself.
zerombr
clearpart --all --initlabel
autopart --type=btrfs --noswap
#%include /tmp/svk-storage.ks
#bootloader --append="rd.luks.options=tpm2-device=auto"
#
# Per-install LUKS passphrase: unique to THIS machine, minted here at install time so
# no shared secret ever lives in the ISO/installer image. Alnum-only (32 chars from
# /dev/urandom) to sidestep any kickstart quoting edge cases. Written into the
# autopart %include consumed above, and stashed at /tmp/svk-luks-bootstrap for the
# %post that seeds the target's /etc/svk/luks-bootstrap. On a machine with NO TPM
# (where first boot would prompt for it), an attended operator can read it before the
# auto-reboot via a console (Ctrl+Alt+F2): `cat /tmp/svk-luks-bootstrap`.
#%pre --erroronfail
#umask 077
#pass="$(head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
#printf '%s\n' "$pass" > /tmp/svk-luks-bootstrap
#printf 'autopart --type=btrfs --noswap --encrypted --passphrase="%s"\n' "$pass" \
#    > /tmp/svk-storage.ks
#%end
EOF
# Second heredoc is unquoted so ${INSTALL_IMAGE_DIR}/${IMAGE_TAG} expand at build time.
cat <<EOF

ostreecontainer --url=${INSTALL_IMAGE_DIR}:${IMAGE_TAG} --transport=oci --no-signature-verification
%include /usr/share/anaconda/post-scripts/svk-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/svk-default-target.ks
%include /usr/share/anaconda/post-scripts/svk-disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/svk-install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/svk-flatpak-selinux.ks
# Disabled with the encryption above (2026-07-28). Both are already inert without
# a %pre-minted passphrase; commented out so the automated installs say so.
#%include /usr/share/anaconda/post-scripts/svk-luks-bootstrap.ks
#%include /usr/share/anaconda/post-scripts/svk-luks-tpm.ks
EOF
}

# --- lab role: the kiosk account ---------------------------------------------
# opilas is created HERE, not by sysusers.d in the image: with one image for the
# whole fleet, the account has to be an install-time decision or every staff
# laptop would grow a kiosk user too. Its password is locked — GDM's autologin
# PAM stack doesn't check one — and it is in no privileged group.
#
# The fleet's id map is fixed on purpose, so every machine looks the same:
#   1000 admin (sysusers, first boot) / 1001 staff / 1002 opilas
# Both the uid and the gid are pinned, and the group is created first, because
# useradd otherwise takes the lowest free id of each — and this runs at INSTALL
# time, before sysusers has created admin, so an unpinned account would grab 1000
# out from under it and push admin onto an arbitrary fallback id.
{ common_ks; cat <<'EOF'
group --name=opilas --gid=1002
user --name=opilas --uid=1002 --gid=1002 --gecos="Kiosk student (opilas)" --lock
rootpw --lock
firstboot --disable
%include /usr/share/anaconda/post-scripts/svk-role-lab.ks
reboot
EOF
} > /usr/share/anaconda/svk-lab.ks

# --- staff role: a normal login ----------------------------------------------
# A REGULAR user: no --groups=wheel, because local sudo is intentionally
# admin-only and over SSH. `svk-staff` is the group that carries the teacher
# privileges the image grants — gnome-software (mode 0750, group svk-staff) and
# the narrow polkit grant for system-scope flatpak installs. The group itself is
# created by sysusers.d in the image, so it already exists here.
#
# It is deliberately NOT called `staff`: useradd refuses to create a user whose
# user-private group name is already taken, which would abort this install. The
# user-private `staff` group is created explicitly below so its gid is pinned to
# 1001 — see the id-map note on the lab kickstart above.
{ common_ks; cat <<EOF
group --name=staff --gid=1001
user --name=staff --uid=1001 --gid=1001 --gecos="Staff" --groups=svk-staff --password=${STAFF_PASSWORD} --plaintext
rootpw --lock
firstboot --disable
%include /usr/share/anaconda/post-scripts/svk-role-staff.ks
reboot
EOF
} > /usr/share/anaconda/svk-staff.ks

# --- role %post: lab ----------------------------------------------------------
# Everything here is machine-local state that the IMAGE deliberately doesn't
# carry, because carrying it would lock down staff laptops too:
#
#   1. GDM autologin. Shipping this in the image would point every machine's
#      greeter at an account most of them don't have.
#   2. DCONF_PROFILE=kiosk. /etc/dconf/profile/user applies to EVERY account on
#      the machine, so the kiosk profile has to be selected per-account instead —
#      environment.d is the supported per-user way, and the account already uses
#      it for LANG (see files/os/etc/skel/.config/environment.d/).
#   3. The `opilas` hidden-launcher set, prepended to XDG_DATA_DIRS: NoDisplay
#      stubs in /usr/share/svk/hidden-apps/opilas shadow the launchers for the
#      apps this account can't execute (build/40-desktop.sh). Content stays in
#      /usr so image updates propagate; only this one-line file is local.
#
# Written into /etc/skel, not into ~opilas: reset-opilas-home.service wipes that
# home back to skel on every logout, so skel is the only place it survives. A lab
# machine has no other interactive account to pollute (admin's home comes from
# tmpfiles.d, never from skel).
tee /usr/share/anaconda/post-scripts/svk-role-lab.ks <<'EOF'
%post --erroronfail
install -d -m 0755 /etc/gdm
cat >/etc/gdm/custom.conf <<'CONF'
# Written by the svk lab kickstart. Autologin straight into `opilas` — no
# greeter, no password prompt. GDM's autologin PAM stack does not check the
# password, so the locked account logs in fine.
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=opilas
CONF

install -d -m 0755 /etc/skel/.config/environment.d
cat >/etc/skel/.config/environment.d/20-svk-role.conf <<'CONF'
# Written by the svk lab kickstart — this machine's role is "lab".
# Replanted into /home/opilas by reset-opilas-home.sh on every logout.
DCONF_PROFILE=kiosk
XDG_DATA_DIRS=/usr/share/svk/hidden-apps/opilas:/usr/local/share:/usr/share
CONF
chmod 0644 /etc/skel/.config/environment.d/20-svk-role.conf
%end
EOF

# --- role %post: staff --------------------------------------------------------
# The staff role gets the `wheel-only` hidden-launcher set (the five admin apps)
# and NO dconf profile override — a staff account is a normal desktop account.
#
# Anaconda creates the `user` account BEFORE %post runs, so its home already
# holds a copy of the pre-role skel; plant the file in both places (skel for any
# account added later, the live home for the one that already exists).
#
# chage -d 0 expires the placeholder password immediately: the teacher is forced
# to set a real one at first login. See the STAFF_PASSWORD note at the top of
# this file — this is an interim measure, not the fix.
tee /usr/share/anaconda/post-scripts/svk-role-staff.ks <<'EOF'
%post --erroronfail
install -d -m 0755 /etc/skel/.config/environment.d
cat >/etc/skel/.config/environment.d/20-svk-role.conf <<'CONF'
# Written by the svk staff kickstart — this machine's role is "staff".
XDG_DATA_DIRS=/usr/share/svk/hidden-apps/wheel-only:/usr/local/share:/usr/share
CONF
chmod 0644 /etc/skel/.config/environment.d/20-svk-role.conf

staff_home="$(getent passwd staff | cut -d: -f6)"
if [ -n "$staff_home" ] && [ -d "$staff_home" ]; then
    mkdir -p "${staff_home}/.config/environment.d"
    cp /etc/skel/.config/environment.d/20-svk-role.conf \
       "${staff_home}/.config/environment.d/20-svk-role.conf"
    chown -R staff: "${staff_home}/.config"
fi

chage -d 0 staff
%end
EOF

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
#
# No role %post here either: an interactively-installed machine gets neither role's
# accounts or environment.d files. It is a plain svk-os desktop, and whoever the
# operator creates in the UI gets the default (unrestricted-launcher) experience.
cat >/usr/share/anaconda/interactive-defaults.ks <<EOF
# svk defaults for an INTERACTIVE install from the live desktop session.
# The unattended route is an automated GRUB entry -> svk-lab.ks / svk-staff.ks.
lang fi_FI.UTF-8
keyboard --vckeymap=fi --xlayouts=fi
timezone Europe/Helsinki --utc

ostreecontainer --url=${INSTALL_IMAGE_DIR}:${IMAGE_TAG} --transport=oci --no-signature-verification
%include /usr/share/anaconda/post-scripts/svk-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/svk-default-target.ks
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

# Put the default target back to graphical.
#
# Anaconda writes /etc/systemd/system/default.target -> multi-user.target into the
# installed system. With an ostreecontainer payload it has no package selection to
# infer a desktop from, so it takes the text default and overrides the image's own
# /usr/lib/systemd/system/default.target -> graphical.target.
#
# The consequence is not subtle, and is invisible until a machine is installed: GDM
# is enabled and never starts, and the machine — lab or staff — comes up at a text
# login prompt. No autologin, no kiosk session, no desktop. Observed on the first
# end-to-end VM install, 2026-08-19. Nothing in the build or the image can catch
# it, because the image is right and the installer changes it afterwards.
tee /usr/share/anaconda/post-scripts/svk-default-target.ks <<'EOF'
%post --erroronfail
systemctl set-default graphical.target
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
# (files/os/usr/libexec/svk/luks-tpm-enroll) consumes it to enroll the TPM +
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
# console (see %pre note) to get that first boot to run.
#
# PCR 7 (Secure Boot state) is identical in the installer and the installed system on
# the same machine; PCRs 4/8/9 are NOT, so bind only PCR 7. That is also svk's
# fleet-wide policy and deliberately looser than Aeon's — do not add PCRs here
# without reading §1 of tasks/done/20260726-2014-fde-tpm-and-install-path.md.
#
# The capability probe (shipped in the image, shared with the first-boot service) runs
# before we commit: a TPM 2.0 older than v1.38 has a /dev/tpmrm0 and still cannot be
# enrolled, so checking for the device alone would just produce a confusing failure
# here and an unexplained passphrase prompt on the deployed machine.
tee /usr/share/anaconda/post-scripts/svk-luks-tpm.ks <<'EOF'
%post --erroronfail
if [ -f /etc/svk/luks-bootstrap ]; then
    if _probe="$(/usr/libexec/svk/tpm2-capable)"; then
        echo "svk: TPM2 probe: ${_probe}"
        _uuid="$(awk '!/^#/ && NF {print $2; exit}' /etc/crypttab | sed 's/^UUID=//')"
        _dev="/dev/disk/by-uuid/${_uuid}"
        if [ -n "$_uuid" ] && [ -e "$_dev" ]; then
            PASSWORD="$(cat /etc/svk/luks-bootstrap)" \
                systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$_dev" \
                || echo "svk: install-time TPM2 enrollment failed; first boot will retry."
        fi
    else
        # Not a failure of the install — this machine simply cannot auto-unlock. The
        # first-boot service re-probes, says so on the console next to the recovery
        # key, and stops retrying instead of prompting forever.
        echo "svk: skipping TPM2 enrollment: ${_probe}"
        echo "svk: this machine will need the recovery key at every boot."
    fi
fi
%end
EOF

### Bake the offline flatpak set into THIS image ###############################
# One list for one image — flatpaks/{student,staff}.list are gone. These land in
# SYSTEM scope (/var/lib/flatpak), which is what makes them survive an opilas home
# reset and what lets a teacher's later system-scope install reach the kiosk too.
curl --retry 3 -Lo /etc/flatpak/remotes.d/flathub.flatpakrepo https://dl.flathub.org/repo/flathub.flatpakrepo
# `grep -v` exits 1 on an empty result and `set -o pipefail` turns that into a
# failed build, so an all-commented list (a deliberately app-free test ISO, or the
# state this would pass through if the set moves to first-boot installation —
# tasks/todo/…-lan-mirror-flatpak-wiring.md) aborted the whole installer build
# instead of baking nothing. `|| true` on the filter keeps that harmless.
mapfile -t svk_flatpaks < <(sed 's/#.*//' /tmp/flatpaks/common.list | tr -d '[:blank:]' | { grep -v '^$' || true; } | sort -u)

# One app at a time, with retries, rather than one `xargs flatpak install` for the
# whole list. This step is a multi-GB download from Flathub and it is the ONLY
# build-time network dependency that is not the registry — CLAUDE.md's own rule
# says to avoid those, and this is why: a single object timing out
# ("[28] Timeout was reached" on LibreOffice, 2026-08-19) failed the entire ISO
# build twenty minutes in, with every other app already downloaded and thrown away.
# Per-app retry turns a blink into a pause. It does not make the dependency go
# away — moving the set to first-boot installation from the LAN mirror does
# (tasks/todo/…-lan-mirror-flatpak-wiring.md).
for app in "${svk_flatpaks[@]:-}"; do
    [ -n "$app" ] || continue
    installed=0
    for attempt in 1 2 3; do
        if flatpak install -y --noninteractive --system flathub "$app"; then
            installed=1
            break
        fi
        echo "svk installer: flatpak install ${app} failed (attempt ${attempt}/3); retrying" >&2
        sleep $(( attempt * 10 ))
    done
    [ "$installed" = 1 ] || { echo "svk installer: giving up on ${app}" >&2; exit 1; }
done

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
# `inst.cmdline`: run fully non-interactive, not just text-mode. If the kickstart
# ever fails to answer something, inst.cmdline ABORTS with the unanswered question
# printed on the console — visible, diagnosable failure. The old `inst.text` would
# instead sit at a prompt forever, which on an unattended provisioning run looks
# identical to a slow install. It also keeps this path off any Wayland compositor
# (the live image has no gnome-kiosk). Progress prints to the console — hence no
# `quiet rhgb` here.
AUTO_ARGS="systemd.unit=anaconda.target inst.cmdline"

# TWO automated entries, one per role. This is how a single ISO provisions both
# kinds of machine: the operator picks the role at boot, and no second USB stick
# or OEMDRV partition has to be managed. Entry 0 stays the default because lab
# machines are the bulk of the fleet and their install is the one that has to be
# hands-off across a whole cart.
mkdir -p /usr/lib/bootc-image-builder
tee /usr/lib/bootc-image-builder/iso.yaml <<EOF
label: "${LABEL}"
grub2:
  timeout: 15
  default: 0
  entries:
    - name: "Install ${DISPLAY_NAME} - LAB machine (opilas kiosk) - automated, ERASES THE DISK"
      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=${LABEL} enforcing=0 rd.live.image ${AUTO_ARGS} inst.kickstart=/usr/share/anaconda/svk-lab.ks"
      initrd: "/images/pxeboot/initrd.img"
    - name: "Install ${DISPLAY_NAME} - STAFF laptop - automated, ERASES THE DISK"
      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=${LABEL} enforcing=0 rd.live.image ${AUTO_ARGS} inst.kickstart=/usr/share/anaconda/svk-staff.ks"
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
  "image-ref": "${IMAGE_REPO}:${IMAGE_TAG}",
  "roles": ["lab", "staff"],
  "iso-git-commit": "${ISO_GIT_SHA:-}",
  "built-at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

dnf5 clean all

echo "svk installer build.sh complete for ${IMAGE_REPO}:${IMAGE_TAG} (roles: lab, staff), iso-git-commit=${ISO_GIT_SHA:-<none>}"
