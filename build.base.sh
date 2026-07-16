#!/usr/bin/bash
# build.base.sh — package installs & system config baked into svk-base.
# Runs once, inside the image build. Keep it lean: everything here ships to
# every desktop in the fleet.
set -euo pipefail

### System packages ###########################################################
# rpm-ostree is the layering tool inside bootc images (dnf is not available the
# usual way). Add packages to this one list.
#
# tailscale        : mesh VPN. Installed only — NO auth key is baked in. Nodes
#                    enroll at provision time (see the Tailscale TODO in README).
# cups / print stack: Bluefin already ships CUPS; we add drivers the school uses.
# fwupd            : firmware updates, matches the existing HP workflow.
#
# Bluefin already includes some of these, and `rpm-ostree install` errors on an
# already-present package — so install idempotently (skip what's already there).
# If a package is genuinely missing AND not in an enabled repo (e.g. tailscale),
# add its repo first: `curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
#   -o /etc/yum.repos.d/tailscale.repo`.
PACKAGES=(
    tailscale
    fwupd
    avahi          # mDNS responder: advertises this box as <hostname>.local
    nss-mdns       # glibc NSS plug-in so .local names *resolve* locally
    # Baseline CLI toolbox on every machine (idempotent — Bluefin ships some).
    htop           # interactive process viewer
    curl           # HTTP client
    wget           # HTTP downloader
    ncdu           # disk-usage explorer
    fd-find        # fast find(1) replacement; provides /usr/bin/fd
    # cups-filters gutenprint hplip   # <-- add the exact print packages you need
    # <<ADD SYSTEM PACKAGES HERE>>    # e.g. school-specific fonts, tools
)
to_install=()
for pkg in "${PACKAGES[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 || to_install+=("$pkg")
done
[ ${#to_install[@]} -gt 0 ] && rpm-ostree install "${to_install[@]}"

# Tailscale ships a daemon unit; enable it so the node is ready to enroll on
# first boot. NOTE: student machines are NOT enrolled (50-device tailnet cap) —
# build.student.sh disables this again; staff and the server stay enrolled.
systemctl enable tailscaled.service

# First-boot enrollment reads the auth key from the provisioning USB and runs
# `tailscale up` (svk-tailscale-enroll.sh). It no-ops where /etc/svk/tailscale.
# conf says TAILSCALE_ENROLL=no (students), so the mechanism ships to every
# desktop but only staff actually enroll. No key is ever baked into an image.
systemctl enable svk-tailscale-enroll.service

### Local name resolution — mDNS / .local ####################################
# The fleet is addressed by name on the LAN (svk-server.local, svk-student-NN
# .local, ...), not just over the tailnet, because student machines never join
# Tailscale. Avahi advertises this host's name; nss-mdns makes .local names
# resolve. Point NSS at mdns (idempotent — skip if the base already has it).
systemctl enable avahi-daemon.service
if ! grep -qE '^hosts:.*mdns' /etc/nsswitch.conf; then
    sed -i -E 's/^(hosts:[[:space:]]+).*/\1files mdns4_minimal [NOTFOUND=return] myhostname resolve [!UNAVAIL=return] dns/' /etc/nsswitch.conf
fi

### Remote administration — SSH ##############################################
# Every device is reachable over the local network as the `admin` operator:
#   - admin (uid 980, in wheel, passwordless sudo via /etc/sudoers.d) is a
#     dedicated, system-range account so it never shows on the GDM greeter and
#     never collides with the interactive opilas/staff user (uid 1000+).
#   - key-only, no password (useradd leaves the account locked); keys come from
#     /etc/ssh/authorized_keys.d/admin (admin operator + svk-server).
#   - `-M`: no build-time home (bootc drops /var/home); it's created at boot by
#     /etc/tmpfiles.d/svk-admin.conf, mirroring how `opilas` is handled.
# sshd hardening (key-only, no root, restricted crypto) lives in
# /etc/ssh/sshd_config.d/10-svk-hardening.conf.
if ! id admin &>/dev/null; then
    useradd -M -u 980 -c "svk local admin" -s /bin/bash -G wheel admin
fi
passwd -l admin                    # belt-and-braces: no password login, key only
chmod 0440 /etc/sudoers.d/10-svk-admin   # visudo-conventional perms (COPY lands 0644)
systemctl enable sshd.service

### GNOME desktop defaults ####################################################
# Compile the fleet-wide desktop defaults (files/base/etc/dconf/db/local.d/
# 00-svk-desktop: window buttons, desktop icons, week numbers, clock weekday)
# into the binary `local` db. The student image runs `dconf update` again after
# adding its lockdown, so both layers end up compiled.
dconf update

### Power profile switching ###################################################
# Laptops: power-saver on battery, balanced on AC. A udev rule re-runs the
# oneshot on every AC plug/unplug; enabling it here also sets the profile once
# at boot so the initial state is correct.
systemctl enable svk-power-profile.service

### Flatpak preinstall ########################################################
# Install the fleet's system Flatpaks (/etc/svk/flatpaks.list) on first boot,
# NOT at build time (build-time `flatpak install` needs network + a remote in CI
# and fails the build if Flathub hiccups). See svk-flatpak-preinstall.sh.
systemctl enable svk-flatpak-preinstall.service

### Fonts #####################################################################
# Drop school-licensed / required fonts into files/base/usr/share/fonts/ and
# they get picked up automatically. Placeholder — add fonts, then:
# fc-cache -f  ||  true    # <-- uncomment if you bake fonts and want the cache warmed

### School CA certificates ####################################################
# Any *.crt placed in files/base/etc/pki/ca-trust/source/anchors/ is trusted
# once we rebuild the trust store here.
update-ca-trust

### First-boot hostname claim #################################################
# Enable the oneshot that asks the server's dispenser for a fleet hostname the
# first time each machine boots. See files/base/usr/bin/svk-claim-hostname.sh
systemctl enable svk-claim-hostname.service

### Container signature policy ################################################
# policy.json (copied via files/base) requires our images to be cosign-signed
# with /etc/pki/containers/svk-cosign.pub. Nothing to run here — just noting
# that the key was copied in by the Containerfile.

### Cleanup ###################################################################
# Keep layers small; commit is handled by rpm-ostree.
rpm-ostree cleanup -m || true
