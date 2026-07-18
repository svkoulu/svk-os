# svk — school bootc image factory. Local build + setup commands.
# Run `just` with no arguments to list recipes. CI does NOT use this file
# (it builds via .github/actions/build-image); this is for local work.

registry := "ghcr.io"
namespace := "svkoulu"
podman := env("PODMAN", "podman")
# Base image the derived (student/staff) builds FROM. Defaults to a locally-built
# base; override to build against the pushed one:
#   just build-staff base_image=ghcr.io/svkoulu/svk-base:latest
local_base := "localhost/svk-base:latest"
# Local build version = local-<date>, e.g. local-20260718 (the `local` channel).
# Stamped into os-release, svk-os/image-info.json + the image.version label so a local
# dev build is clearly not a CI stable/testing image. CI computes stable-/testing-<date>.
version := "local-" + `date +%Y%m%d`

[private]
default:
    @just --list

# ── Build ───────────────────────────────────────────────────────────────────

# Build svk-base (every desktop image builds FROM it).
[group('build')]
build-base:
    {{ podman }} build -f Containerfile.base --build-arg VERSION={{ version }} -t svk-base .

# Build svk-staff (needs svk-base built first, or pass base_image=<ghcr ref>).
[group('build')]
build-staff base_image=local_base:
    {{ podman }} build -f Containerfile.staff --build-arg BASE_IMAGE={{ base_image }} --build-arg VERSION={{ version }} -t svk-staff .

# Build svk-student (needs svk-base built first, or pass base_image=<ghcr ref>).
[group('build')]
build-student base_image=local_base:
    {{ podman }} build -f Containerfile.student --build-arg BASE_IMAGE={{ base_image }} --build-arg VERSION={{ version }} -t svk-student .

# Build the uCore server image (independent of svk-base).
[group('build')]
build-server:
    {{ podman }} build -f Containerfile.server --build-arg VERSION={{ version }} -t svk-server .

# Build base + both desktops, in dependency order.
[group('build')]
build-desktops: build-base build-staff build-student

# Build all four images.
[group('build')]
build-all: build-desktops build-server

# Build an installer ISO with Titanoboa. flavor=student|staff  repo=local|ghcr
# channel=stable|testing (only meaningful for repo=ghcr; stable needs a cut git tag).
# Needs a real host with root podman + AC power (heavy). NOT yet validated.
[group('build')]
iso flavor="student" repo="local" channel="stable":
    iso/build-iso.sh {{ flavor }} {{ repo }} {{ channel }}

# Boot the newest locally-built installer ISO in a throwaway VM to test the installer
# end-to-end (install -> reboot -> first boot). Uses the qemux/qemu container, so it
# needs KVM (/dev/kvm) + podman but NO host qemu or swtpm. TPM=Y gives the guest an
# emulated TPM 2.0, so the full LUKS + TPM auto-unlock path is exercised (install-time
# %post enrollment, then auto-unlock on reboot with no passphrase prompt). Opens the
# web console (localhost:8006) and installs to an ephemeral disk that's discarded on
# exit. flavor=student|staff.
[group('build')]
run-iso flavor="student":
    #!/usr/bin/env bash
    set -euo pipefail
    iso="$(ls -t iso/svk-{{ flavor }}-*.iso 2>/dev/null | head -1 || true)"
    [ -n "$iso" ] || { echo "No iso/svk-{{ flavor }}-*.iso found — run 'just iso {{ flavor }} local' first."; exit 1; }
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
        --env RAM_SIZE=6G --env CPU_CORES=4 --env DISK_SIZE=32G --env BOOT_MODE=uefi --env TPM=Y \
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
# be the svk-server line in files/base/etc/ssh/authorized_keys.d/admin.
[group('setup')]
bootstrap-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p secrets
    if [ ! -f secrets/id_ed25519 ]; then
        ssh-keygen -t ed25519 -C svk-server -N '' -f secrets/id_ed25519
        echo ">> Put secrets/id_ed25519.pub as the svk-server line in files/base/etc/ssh/authorized_keys.d/admin"
    else
        echo "secrets/id_ed25519 already exists."
    fi
    [ -f secrets/tailscale-authkey ] || echo ">> TODO: create secrets/tailscale-authkey (server pre-auth key) — see secrets/README.md"

# Copy the student Wi-Fi profile template to its real (gitignored) path to fill in.
[group('setup')]
wifi-profile:
    #!/usr/bin/env bash
    set -euo pipefail
    d=files/student/etc/NetworkManager/system-connections
    real="$d/svk-student-wifi.nmconnection"
    [ -f "$real" ] && { echo "$real already exists."; exit 0; }
    cp "$real.example" "$real"
    echo ">> Created $real (gitignored). Fill in SSID/PSK, then build svk-student."

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
    shellcheck build/*.sh build.*.sh iso/*.sh

# Remove locally-built svk images.
[group('utility')]
clean:
    -{{ podman }} rmi svk-base svk-student svk-staff svk-server

# Check Justfile formatting.
[group('utility')]
check:
    just --unstable --fmt --check
