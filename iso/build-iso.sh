#!/usr/bin/env bash
# build-iso.sh — build one svk desktop ISO with Titanoboa (container-native ISO
# contract: https://github.com/ondrejbudai/bootc-isos).
#
#   Usage: iso/build-iso.sh <flavor> [repo] [channel]
#     flavor  : student | staff
#     repo    : ghcr (default) | local
#     channel : stable (default) | testing — only meaningful for repo=ghcr
#
# What it does:
#   1. Gets the svk-<flavor> image into root's podman storage (Titanoboa/the
#      installer build need root podman for loop devices + privileged mounts).
#   2. Builds a throwaway "installer image" (iso/installer/) FROM that image:
#      Anaconda + the offline flatpak bake + live-boot support + iso.yaml. Never
#      pushed anywhere — it only exists to feed Titanoboa.
#   3. Runs Titanoboa (pinned commit) against that installer image to squashfs it
#      into a boot-and-run LiveOS ISO.
#   4. Copies the resulting ISO to iso/svk-<flavor>-<version>.iso (version from
#      the target image's image.version label, e.g. 1-20260718).
#
# Needs a real host with root podman + AC power (ISO builds are heavy).
set -euo pipefail

# --- Titanoboa pin. Track ublue-os/titanoboa; bump deliberately (upstream did a
# breaking rewrite in #138 that dropped its old Justfile/hook interface — pin to
# an exact commit, not a moving branch, so that doesn't happen again silently). --
TITANOBOA_REPO="https://github.com/ublue-os/titanoboa"
TITANOBOA_REF="5c457c3d0518bd17e754be0fd98a60d29d26abb4" # main @ 2026-05-19, container-native rewrite (#138)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-svkoulu}"
REGISTRY="${REGISTRY:-ghcr.io}"

# `sudo`'s secure_path often doesn't include wherever podman actually lives (e.g.
# /usr/local/bin), so a bare `sudo podman` can fail with "command not found" even
# though passwordless sudo itself works fine — resolve the absolute path once and
# always invoke sudo with that, never with the bare command name.
PODMAN="$(command -v podman)"

# Prime sudo's credential cache up front and keep it alive for the whole script:
# without this, a long step (e.g. copying a multi-GB image) can outlast sudo's
# timestamp, and a later sudo call fails with "a password is required" since
# there's no TTY to re-prompt in this non-interactive pipeline.
sudo -v
( while true; do sudo -n -v; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

flavor="${1:?usage: build-iso.sh <student|staff> [ghcr|local] [stable|testing]}"
repo="${2:-ghcr}"
channel="${3:-stable}"
case "$flavor" in student|staff) ;; *) echo "flavor must be student|staff" >&2; exit 1 ;; esac
case "$channel" in stable|testing) ;; *) echo "channel must be stable|testing" >&2; exit 1 ;; esac

# The real ref the installed machine should track — used for the kickstart's
# ostreecontainer/bootc-switch target regardless of what the installer image is
# built FROM. Even a repo=local test install should end up pointed at a real,
# fetchable origin (not localhost/..., which wouldn't exist on real hardware).
IMAGE_REF="${REGISTRY}/${NAMESPACE}/svk-${flavor}:${channel}"

case "$repo" in
    ghcr)  BASE_IMAGE="$IMAGE_REF" ;;
    local) BASE_IMAGE="localhost/svk-${flavor}:latest" ;;
    *) echo "repo must be ghcr|local" >&2; exit 1 ;;
esac

# --- 1. Make sure BASE_IMAGE is in root's podman storage -----------------------
# Titanoboa and the installer-image build both need root podman. For repo=local
# this always re-copies rather than checking "does root already have this tag" —
# :latest is a moving tag, so a stale check would silently keep building the ISO
# from whatever old content a previous run last copied in, never picking up a
# rebuilt local image.
if [ "$repo" = "ghcr" ]; then
    sudo "$PODMAN" pull "$BASE_IMAGE"
else
    podman image scp "$(id -un)@localhost::${BASE_IMAGE}" "root@localhost::${BASE_IMAGE}"
fi

# --- 2. Build the throwaway installer image ------------------------------------
# Read BASE_IMAGE's own version label (e.g. stable-1-20260719 / testing-20260719 /
# local-20260719) so the GRUB boot-menu entry can show the exact version being
# installed, not just the rolling channel alias in IMAGE_REF. Same label build-iso
# step 5 uses to name the ISO file — read once here, reused there.
IMG_VERSION="$(sudo "$PODMAN" inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$BASE_IMAGE" 2>/dev/null || true)"
# BASE_IMAGE's own commit (stamped by Containerfile.{staff,student}'s GIT_SHA
# build-arg) — the source commit the PACKAGED IMAGE was built from. Reported
# alongside ISO_GIT_SHA below since the two can legitimately differ (an ISO can be
# rebuilt with newer iso/ scripts against an older, already-published image).
IMG_GIT_SHA="$(sudo "$PODMAN" inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$BASE_IMAGE" 2>/dev/null || true)"
# Commit of THIS svk repo checkout, i.e. the iso/ scripts assembling this ISO —
# distinct from IMG_GIT_SHA above. Stamped into the live environment as
# svk-os/iso-build-info.json (see iso/installer/build.sh).
ISO_GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"

# Temporary LUKS passphrase used only to create the encrypted disk during install.
# Fresh per build so it isn't a committed/reused secret; the target's first-boot
# svk-luks-tpm-enroll.service wipes this slot after enrolling TPM2 + a per-machine
# recovery key, so it never unlocks anything on the deployed fleet.
LUKS_BOOTSTRAP_PASSPHRASE="$(openssl rand -base64 24)"
INSTALLER_IMAGE="localhost/svk-${flavor}-installer:latest"
sudo "$PODMAN" build \
    --cap-add sys_admin --security-opt label=disable \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg FLAVOR="$flavor" \
    --build-arg IMAGE_REF="$IMAGE_REF" \
    --build-arg VERSION="$IMG_VERSION" \
    --build-arg LUKS_BOOTSTRAP_PASSPHRASE="$LUKS_BOOTSTRAP_PASSPHRASE" \
    --build-arg ISO_GIT_SHA="$ISO_GIT_SHA" \
    -t "$INSTALLER_IMAGE" \
    -f "${REPO_ROOT}/iso/installer/Containerfile" \
    "$REPO_ROOT"

# --- 3. Fetch Titanoboa (pinned) ------------------------------------------------
BUILD_DIR="${REPO_ROOT}/iso/.build/${flavor}"
if [ ! -f "${BUILD_DIR}/main.sh" ]; then
    echo "Fetching Titanoboa (${TITANOBOA_REF})..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    tmp="$(mktemp -d)"
    git clone --quiet "$TITANOBOA_REPO" "$tmp"
    git -C "$tmp" checkout --quiet "$TITANOBOA_REF"
    rsync -a --exclude='.git/' "$tmp/" "$BUILD_DIR/"
    rm -rf "$tmp"
fi
# main.sh does its own internal `sudo podman run` — same bare-command PATH problem
# as above, in code we don't control. Patch our pinned local copy to use the
# resolved absolute path too (idempotent: no-op once already patched).
sed -i "s|sudo podman run|sudo \"\$PODMAN\" run|" "${BUILD_DIR}/main.sh"

# Unmerged upstream fix (https://github.com/ublue-os/titanoboa/pull/147, base
# commit == our pin): mksquashfs treats everything after the first -e as exclude
# names, so `-comp zstd -Xcompression-level 19` after `-e sysroot -e ostree` gets
# swallowed as bogus excludes and silently falls back to gzip — bigger ISOs, slower
# live-boot reads. Apply the one-line reorder locally instead of pinning to an
# unreviewed fork branch that could move or disappear; drop this once a real
# upstream commit with the fix lands and TITANOBOA_REF is bumped past it.
sed -i \
    's|mksquashfs /rootfs /work/iso-root/LiveOS/squashfs.img -all-root -noappend -e sysroot -e ostree -comp zstd -Xcompression-level 19|mksquashfs /rootfs /work/iso-root/LiveOS/squashfs.img -all-root -noappend -comp zstd -Xcompression-level 19 -e sysroot ostree|' \
    "${BUILD_DIR}/build_iso.sh"

# --- 4. Build the ISO -----------------------------------------------------------
# main.sh escalates internally via its own single `sudo podman run` — do NOT wrap
# this call in sudo yourself, or you'll hit an unauthenticated nested-sudo prompt
# (root has no sudo rules of its own on most hosts). Since the installer image was
# just built with `sudo podman build`, it's already in root's storage, so that
# internal `--mount type=image` finds it directly.
cd "$BUILD_DIR"
iso_path="$(env TITANOBOA_CTR_IMAGE="$INSTALLER_IMAGE" PODMAN="$PODMAN" ./main.sh)"

# --- 5. Collect the ISO ----------------------------------------------------------
# Name the ISO after the exact image version it targets (the image.version label /
# os-release IMAGE_VERSION, e.g. 1-20260718) so the ISO, the image tag and os-release
# all report one matching version. Local dev images may carry none -> fall back to date.
img_ver="$IMG_VERSION"
[ -n "$img_ver" ] || img_ver="$(date +%Y%m%d)"
out="${REPO_ROOT}/iso/svk-${flavor}-${img_ver}.iso"
sudo chown "$(id -u):$(id -g)" "$iso_path"
mv "$iso_path" "$out"

# Surface the bootstrap passphrase as a FALLBACK. The TPM is pre-enrolled at install
# time (svk-luks-tpm.ks %post), so machines with a TPM auto-unlock from first boot
# with no prompt. This passphrase is only needed if a machine has no TPM (or a PCR
# mismatch) and stops at the disk-unlock prompt. Written 0600 next to the ISO
# (gitignored) and echoed; the first-boot service wipes it from installed machines.
pass_file="${out%.iso}.luks-bootstrap.txt"
( umask 077; printf '%s\n' "$LUKS_BOOTSTRAP_PASSPHRASE" >"$pass_file" )
echo "SUCCESS: ${out}"
echo
echo "  Packaged image commit (svk-${flavor}): ${IMG_GIT_SHA:-<none>}"
echo "  iso/ scripts commit (this build):      ${ISO_GIT_SHA:-<none>}"
echo
echo "  LUKS bootstrap passphrase for this ISO (FALLBACK only — the TPM is pre-enrolled"
echo "  so machines normally auto-unlock; needed if one has no TPM and prompts):"
echo
echo "      ${LUKS_BOOTSTRAP_PASSPHRASE}"
echo
echo "  Also saved to: ${pass_file}  (keep it safe; delete once all machines are provisioned)"
