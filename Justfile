# svk — school bootc image factory. Local build + setup commands.
# Run `just` with no arguments to list recipes. CI does NOT use this file
# (it builds via .github/actions/build-image); this is for local work.

registry := "ghcr.io"
namespace := "svkoulu"
podman := env("PODMAN", "podman")
# Local build version = local-<date>, e.g. local-20260718 (the `local` channel).
# Stamped into os-release, svk-os/image-info.json + the image.version label so a local
# dev build is clearly not a CI stable/testing image. CI computes stable-/testing-<date>.
version := "local-" + `date +%Y%m%d`
# Full commit SHA of the checkout doing the build — stamped as org.opencontainers.
# image.revision + os-release BUILD_ID, independent of the version/channel scheme
# above, so a running image can be traced back to its exact source commit.
git_sha := `git rev-parse HEAD`

[private]
default:
    @just --list

# ── Build ───────────────────────────────────────────────────────────────────

# Build svk-os — THE desktop image (lab machines and staff laptops both run it).
[group('build')]
build-os:
    {{ podman }} build -f Containerfile.os --build-arg VERSION={{ version }} --build-arg GIT_SHA={{ git_sha }} -t svk-os .

# Build the uCore server image (independent of svk-os).
[group('build')]
build-server:
    {{ podman }} build -f Containerfile.server --build-arg VERSION={{ version }} --build-arg GIT_SHA={{ git_sha }} -t svk-server .

# Build both images (they're independent — no ordering needed).
[group('build')]
build-all: build-os build-server

# Build THE installer ISO with Titanoboa. One ISO for the whole fleet: the role
# (lab / staff) is picked from the GRUB menu at boot, not chosen here.
# repo=local|ghcr  channel=stable|testing (only meaningful for repo=ghcr; stable
# needs a cut git tag). Needs a real host with root podman + AC power (heavy).
[group('build')]
iso repo="local" channel="stable":
    iso/build-iso.sh {{ repo }} {{ channel }}

# Boot the newest locally-built installer ISO in a throwaway VM to test the installer
# end-to-end (install -> reboot -> first boot). Uses the qemux/qemu container, so it
# needs KVM (/dev/kvm) + podman but NO host qemu or swtpm. TPM=Y gives the guest an
# emulated TPM 2.0, so the full LUKS + TPM auto-unlock path is exercised (install-time
# %post enrollment, then auto-unlock on reboot with no passphrase prompt). Opens the
# web console (localhost:8006) and installs to an ephemeral disk that's discarded on
# exit. Pick the role (lab / staff) in the guest's GRUB menu.
[group('build')]
run-iso:
    #!/usr/bin/env bash
    set -euo pipefail
    iso="$(ls -t iso/svk-os-*.iso 2>/dev/null | head -1 || true)"
    [ -n "$iso" ] || { echo "No iso/svk-os-*.iso found — run 'just iso local' first."; exit 1; }
    [ -e /dev/kvm ] || { echo "No /dev/kvm — this VM runner needs KVM."; exit 1; }
    # Pick a free host port for the web console.
    port=8006
    while ss -tuln 2>/dev/null | grep -q ":${port}\b"; do port=$((port + 1)); done
    echo "Booting ${iso} — web console: http://localhost:${port}"
    ( sleep 25 && command -v xdg-open >/dev/null && xdg-open "http://localhost:${port}" ) &
    {{ podman }} run --rm -it \
        --device=/dev/kvm \
        --cap-add NET_ADMIN \
        --publish "127.0.0.1:${port}:8006" \
        --env RAM_SIZE=8G --env CPU_CORES=8 --env DISK_SIZE=40G --env BOOT_MODE=uefi --env TPM=Y \
        --volume "$(pwd)/${iso}:/boot.iso:z" \
        docker.io/qemux/qemu

# ── Setup / secrets ─────────────────────────────────────────────────────────

# Generate the cosign signing keypair. Commit cosign.pub; NEVER commit cosign.key
# (gitignored) — add its contents as the COSIGN_PRIVATE_KEY repo secret.
[group('setup')]
cosign-keygen:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f cosign.key ] && { echo "cosign.key exists — refusing to overwrite."; exit 0; }
    cosign generate-key-pair
    echo "Done. Commit cosign.pub; add cosign.key -> COSIGN_PRIVATE_KEY secret."

# Generate the server's outbound SSH key into secrets/ (idempotent). Its .pub must
# be the svk-server line in files/os/etc/ssh/authorized_keys.d/admin.
[group('setup')]
bootstrap-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p secrets
    if [ ! -f secrets/id_ed25519 ]; then
        ssh-keygen -t ed25519 -C svk-server -N '' -f secrets/id_ed25519
        echo ">> Put secrets/id_ed25519.pub as the svk-server line in files/os/etc/ssh/authorized_keys.d/admin"
    else
        echo "secrets/id_ed25519 already exists."
    fi
    [ -f secrets/tailscale-authkey ] || echo ">> TODO: create secrets/tailscale-authkey (server pre-auth key) — see secrets/README.md"

# Copy the lab Wi-Fi profile template to its real (gitignored) path to fill in.
[group('setup')]
wifi-profile:
    #!/usr/bin/env bash
    set -euo pipefail
    d=files/os/etc/NetworkManager/system-connections
    real="$d/svk-student-wifi.nmconnection"
    [ -f "$real" ] && { echo "$real already exists."; exit 0; }
    cp "$real.example" "$real"
    echo ">> Created $real (gitignored). Fill in SSID/PSK, then build svk-os."

# Compile server.bu (+ secrets/) into server.ign for the uCore install (gitignored).
[group('setup')]
server-ign:
    butane --pretty --strict --files-dir . server.bu > server.ign
    @echo ">> Wrote server.ign (holds secrets in cleartext — gitignored)."
    @echo "   Install: coreos-installer install /dev/sdX --ignition-file server.ign"

# List any remaining <<PLACEHOLDER>> markers to fill before building.
[group('setup')]
placeholders:
    @grep -rn '<<' --include='*.sh' --include='Containerfile*' --include='*.conf' \
        --include='*.json' --include='*.yaml' --include='*.bu' --include='*.list' \
        --include='*.nmconnection*' . | grep -v '/archived/' || echo "No placeholders left."

# ── Utility ─────────────────────────────────────────────────────────────────

# Shellcheck the build scripts.
[group('utility')]
lint:
    shellcheck build/*.sh build.*.sh iso/*.sh iso/installer/build.sh

# Remove locally-built svk images.
[group('utility')]
clean:
    -{{ podman }} rmi svk-os svk-server

# Check Justfile formatting.
[group('utility')]
check:
    just --unstable --fmt --check
