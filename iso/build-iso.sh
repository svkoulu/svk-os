#!/usr/bin/env bash
# build-iso.sh — build one svk desktop ISO with Titanoboa (offline flatpak bake).
#
#   Usage: iso/build-iso.sh <flavor> [repo]
#     flavor : student | staff
#     repo   : ghcr (default) | local
#
# What it does (adapted from projectbluefin/iso's hack/local-iso-build.sh):
#   1. Assembles the flavor's flatpak list  = flatpaks/common.list + <flavor>.list
#   2. Clones Titanoboa (pinned) into iso/.build/<flavor>/
#   3. Runs Titanoboa's `just build <image> 1 flatpaks.list`, passing svk's
#      hook-anaconda.sh as HOOK_post_rootfs and the image ref as SVK_IMAGE_REF.
#   4. Copies the resulting ISO to iso/svk-<flavor>-<version>.iso (version from the
#      baked image's image.version label, e.g. 1-20260718)
#
# Titanoboa needs root podman (loop devices for ISO creation) — run on a real host
# with sudo, not inside a rootless dev container. NEEDS AC POWER (ISO builds are
# heavy) and is NOT yet validated end-to-end.
set -euo pipefail

# --- Titanoboa pin (N3). Track ublue-os/titanoboa; bump via Renovate. ----------
# TODO(validate): set to a real, tested commit/tag. @main is the moving default.
TITANOBOA_REPO="https://github.com/ublue-os/titanoboa"
TITANOBOA_REF="main"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-svkoulu}"
REGISTRY="${REGISTRY:-ghcr.io}"

flavor="${1:?usage: build-iso.sh <student|staff> [ghcr|local]}"
repo="${2:-ghcr}"
case "$flavor" in student|staff) ;; *) echo "flavor must be student|staff" >&2; exit 1 ;; esac

# The fleet installs the STABLE channel, so ghcr ISOs bake :stable (needs at least
# one cut git tag). Override IMAGE_REF in the env to bake a different tag/channel.
case "$repo" in
    ghcr)  IMAGE_REF="${IMAGE_REF:-${REGISTRY}/${NAMESPACE}/svk-${flavor}:stable}" ;;
    local) IMAGE_REF="localhost/svk-${flavor}:latest" ;;
    *) echo "repo must be ghcr|local" >&2; exit 1 ;;
esac

BUILD_DIR="${REPO_ROOT}/iso/.build/${flavor}"
mkdir -p "$BUILD_DIR"

# --- 1. Assemble the flatpak list (shared + per-flavor), stripped of comments ---
FLATPAK_LIST="${BUILD_DIR}/flatpaks.list"
cat "${REPO_ROOT}/flatpaks/common.list" "${REPO_ROOT}/flatpaks/${flavor}.list" \
    | sed 's/#.*//' | tr -d '[:blank:]' | grep -v '^$' | sort -u > "$FLATPAK_LIST"
echo "Flatpaks to bake into svk-${flavor}:"; cat "$FLATPAK_LIST"

# --- 2. Fetch Titanoboa (pinned) -----------------------------------------------
if [ ! -f "${BUILD_DIR}/Justfile" ]; then
    echo "Fetching Titanoboa (${TITANOBOA_REF})..."
    tmp="$(mktemp -d)"
    git clone --depth 1 --branch "$TITANOBOA_REF" "$TITANOBOA_REPO" "$tmp"
    rsync -a --exclude='work/' "$tmp/" "$BUILD_DIR/"
    rm -rf "$tmp"
fi

# --- 3. Make sure the target image is in root's podman storage -----------------
# Titanoboa reads the image from root's containers-storage.
if [ "$repo" = "ghcr" ]; then
    sudo podman pull "$IMAGE_REF"
else
    # local: copy from the (rootless) user store into root's store if needed.
    sudo podman image exists "$IMAGE_REF" || \
        podman image scp "$(id -un)@localhost::${IMAGE_REF}" "root@localhost::${IMAGE_REF}"
fi

# --- 4. Build the ISO ----------------------------------------------------------
cp "${REPO_ROOT}/iso/hook-anaconda.sh" "${BUILD_DIR}/hook.sh"
cd "$BUILD_DIR"
echo "Running Titanoboa build for ${IMAGE_REF}..."
sudo env \
    TITANOBOA_BUILDER_DISTRO="fedora" \
    HOOK_post_rootfs="hook.sh" \
    SVK_IMAGE_REF="$IMAGE_REF" \
    just PODMAN="podman" build "$IMAGE_REF" 1 flatpaks.list

# --- 5. Collect the ISO --------------------------------------------------------
# Name the ISO after the exact image version it baked (the image.version label /
# os-release IMAGE_VERSION, e.g. 1-20260718) so the ISO, the image tag and os-release
# all report one matching version. Local dev images may carry none -> fall back to date.
img_ver="$(sudo podman inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE_REF" 2>/dev/null || true)"
[ -n "$img_ver" ] || img_ver="$(date +%Y%m%d)"
out="${REPO_ROOT}/iso/svk-${flavor}-${img_ver}.iso"
if [ -f "${BUILD_DIR}/output.iso" ]; then
    cp "${BUILD_DIR}/output.iso" "$out"
    echo "SUCCESS: ${out}"
else
    echo "ERROR: Titanoboa produced no output.iso" >&2
    exit 1
fi
