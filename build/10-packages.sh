#!/usr/bin/bash
# 10-packages.sh — package layer for svk-base (dnf5 on a raw Silverblue base).
#
# Unlike the old `FROM bluefin` build, this base is vanilla Fedora Silverblue, so
# packages we need aren't already present and we add them explicitly. dnf5 install
# is a no-op for anything already shipped, so no `rpm -q` guards are needed.
set -euo pipefail

echo "::group:: Exclude RPM Firefox (D3 — svk ships Flatpak Firefox via the ISO)"
# Silverblue ships firefox as an RPM. Remove it (mirrors Bluefin's own exclusion)
# so only the Flatpak — baked into the Titanoboa ISO — is present. The uBO managed
# policy in files/base/etc/firefox/policies/ targets the Flatpak and is untouched.
if rpm -q firefox >/dev/null 2>&1; then
    dnf5 remove -y firefox firefox-langpacks
fi
echo "::endgroup::"

echo "::group:: Tailscale repo"
# Tailscale isn't in Fedora's repos; add its own. NO auth key is baked — nodes
# enrol at provision time (svk-tailscale-enroll.service reads a key off the USB).
curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
    -o /etc/yum.repos.d/tailscale.repo
echo "::endgroup::"

echo "::group:: Install packages"
dnf5 install -y \
    tailscale \
    fwupd \
    avahi \
    nss-mdns \
    htop \
    curl \
    wget \
    ncdu \
    fd-find \
    glibc-langpack-fi \
    qrencode \
    tpm2-tools
    # Print stack — add exactly what the school needs, e.g.:
    #   cups-filters gutenprint hplip
    # <<ADD SYSTEM PACKAGES HERE>>  (school fonts, tools, ...)
echo "::endgroup::"
