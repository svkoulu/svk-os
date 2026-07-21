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
    tpm2-tools \
    dmidecode \
    jq \
    just
    # Print stack — add exactly what the school needs, e.g.:
    #   cups-filters gutenprint hplip
    # <<ADD SYSTEM PACKAGES HERE>>  (school fonts, tools, ...)
echo "::endgroup::"

echo "::group:: ujust — consolidate custom/ujust/*.just, install the wrapper"
# svk gets its own `ujust`-flavored command rather than ublue-os/bling's actual
# ujust binary (a COPR package with gum as a runtime dependency — the same
# class of new-trust-root trade-off already rejected for uupd). This is just a
# thin exec wrapper around Fedora's own `just`, pointed at a consolidated
# justfile assembled from custom/ujust/ at build time. See
# tasks/todo/…-fleet-update-cadence.md.
mkdir -p /usr/share/svk
cat >/usr/share/svk/svk.just <<'JUSTEOF'
# svk.just — consolidated from custom/ujust/*.just at build time by
# build/10-packages.sh. Run `ujust` with no arguments to list commands.
_default:
    @just --justfile {{justfile()}} --list --list-heading $'svk fleet commands:\n' --list-prefix $'  '

JUSTEOF
for f in /ctx/custom/ujust/*.just; do
    [ -e "$f" ] || continue
    cat "$f" >>/usr/share/svk/svk.just
    printf '\n' >>/usr/share/svk/svk.just
done

cat >/usr/bin/ujust <<'WRAPEOF'
#!/usr/bin/bash
exec just --justfile /usr/share/svk/svk.just "$@"
WRAPEOF
chmod 755 /usr/bin/ujust
echo "::endgroup::"
