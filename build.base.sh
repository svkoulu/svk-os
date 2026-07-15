#!/usr/bin/bash
# build.base.sh — package installs & system config baked into school-base.
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
    # cups-filters gutenprint hplip   # <-- add the exact print packages you need
    # <<ADD SYSTEM PACKAGES HERE>>    # e.g. school-specific fonts, tools
)
to_install=()
for pkg in "${PACKAGES[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 || to_install+=("$pkg")
done
[ ${#to_install[@]} -gt 0 ] && rpm-ostree install "${to_install[@]}"

# Tailscale ships a daemon unit; enable it so the node is ready to enroll on
# first boot. `tailscale up` (with the tag + auth key) still happens at
# provision time — enabling the daemon bakes in no secret.
systemctl enable tailscaled.service

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
# first time each machine boots. See files/base/usr/bin/school-claim-hostname.sh
systemctl enable school-claim-hostname.service

### Container signature policy ################################################
# policy.json (copied via files/base) requires our images to be cosign-signed
# with /etc/pki/containers/school-cosign.pub. Nothing to run here — just noting
# that the key was copied in by the Containerfile.

### Cleanup ###################################################################
# Keep layers small; commit is handled by rpm-ostree.
rpm-ostree cleanup -m || true
