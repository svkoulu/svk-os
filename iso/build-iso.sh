#!/usr/bin/env bash
# build-iso.sh — build THE svk installer ISO with Titanoboa (container-native ISO
# contract: https://github.com/ondrejbudai/bootc-isos).
#
#   Usage: iso/build-iso.sh [repo] [channel]
#     repo    : ghcr (default) | local
#     channel : stable (default) | testing — only meaningful for repo=ghcr
#
# ONE ISO for the whole fleet: it bakes both role kickstarts and the operator picks
# lab or staff from the GRUB menu at boot (see iso/installer/build.sh). There is no
# flavor argument any more — svk-student and svk-staff collapsed into svk-os.
#
# What it does:
#   1. For a local build, exports the svk-os image to an OCI archive the installer
#      build bind-mounts in (see step 2); a ghcr build just pulls it.
#   2. Builds a throwaway "installer image" (iso/installer/) FROM that image:
#      Anaconda + both kickstarts + the offline flatpak bake + live-boot support +
#      iso.yaml. Never pushed anywhere — it only exists to feed Titanoboa.
#   3. Runs Titanoboa (pinned commit) against that installer image to squashfs it
#      into a boot-and-run LiveOS ISO.
#   4. Copies the resulting ISO to iso/svk-os-<version>.iso (version from the
#      target image's image.version label, e.g. stable-1-20260718).
#
# Runs entirely ROOTLESS (see the note below). Needs AC power and ~45 GB free
# (ISO builds are heavy) — see iso/README.md for the disk breakdown.
set -euo pipefail

# --- Titanoboa pin. Track ublue-os/titanoboa; bump deliberately (upstream did a
# breaking rewrite in #138 that dropped its old Justfile/hook interface — pin to
# an exact commit, not a moving branch, so that doesn't happen again silently). --
TITANOBOA_REPO="https://github.com/ublue-os/titanoboa"
TITANOBOA_REF="5c457c3d0518bd17e754be0fd98a60d29d26abb4" # main @ 2026-05-19, container-native rewrite (#138)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-svkoulu}"
REGISTRY="${REGISTRY:-ghcr.io}"

# --- ROOTLESS, deliberately. ---------------------------------------------------
# No step here needs root, so none of them asks for it, and nothing is copied into
# root's podman storage. `--cap-add sys_admin` is a *namespaced* capability that a
# rootless container is free to hold, and Titanoboa's payload never touches a loop
# device or a real uid: mksquashfs runs `-all-root`, the EFI image is mkfs.fat +
# mcopy on an ordinary file, and xorriso writes a file. This was the finding of the
# first end-to-end VM install (tasks/…-first-end-to-end-vm-install.md, 2026-08-19),
# and it removes a whole class of failure — the multi-GB user->root image copy, the
# sudo credential-cache dance, and `sudo podman` not working through a distrobox
# host bridge.
#
# Running the WHOLE script under sudo still works (one store, one uid). What must
# never come back is `sudo` on individual steps: that splits the images across two
# stores, which is the only reason a copy step ever existed.

repo="${1:-ghcr}"
channel="${2:-stable}"
case "$channel" in stable|testing) ;; *) echo "channel must be stable|testing" >&2; exit 1 ;; esac

# The real ref the installed machine should track — used for the kickstart's
# ostreecontainer/bootc-switch target regardless of what the installer image is
# built FROM. Even a repo=local test install should end up pointed at a real,
# fetchable origin (not localhost/..., which wouldn't exist on real hardware).
IMAGE_REF="${REGISTRY}/${NAMESPACE}/svk-os:${channel}"

case "$repo" in
    ghcr)  BASE_IMAGE="$IMAGE_REF" ;;
    local) BASE_IMAGE="localhost/svk-os:latest" ;;
    *) echo "repo must be ghcr|local" >&2; exit 1 ;;
esac

# --- 1. Make sure BASE_IMAGE is available ---------------------------------------
# Everything downstream reads the image out of THIS user's podman storage, so a
# local build needs nothing here beyond the export below, and a ghcr build just
# pulls. The export is unconditional rather than cached on "is the archive still
# there": :latest is a moving tag, so a stale check would silently keep building
# the ISO from whatever old content a previous run left behind.
# iso/.local-image/ is bind-mounted into the installer build (see
# iso/installer/Containerfile). For a ghcr build it stays empty and the installer
# pulls the published image; for a local build it carries an OCI archive of the
# image we just built, which is the ONLY way a local build actually installs
# local content — the installer image bakes its own copy of the target as an OCI
# layout for Anaconda to install from, and building FROM the image does not
# provide one (same content, no manifest/config).
LOCAL_IMAGE_DIR="${REPO_ROOT}/iso/.local-image"
rm -rf "$LOCAL_IMAGE_DIR"; mkdir -p "$LOCAL_IMAGE_DIR"
# The archive is image-sized (multi-GB) and pure build input — never leave it
# behind, on success or failure.
trap 'rm -rf "$LOCAL_IMAGE_DIR"' EXIT

if [ "$repo" = "ghcr" ]; then
    podman pull "$BASE_IMAGE"
else
    echo "Exporting ${BASE_IMAGE} for the installer's baked install payload (multi-GB, one-off)..."
    podman save --format oci-archive -o "${LOCAL_IMAGE_DIR}/image.tar" "$BASE_IMAGE"
fi

# --- 2. Build the throwaway installer image ------------------------------------
# Read BASE_IMAGE's own version label (e.g. stable-1-20260719 / testing-20260719 /
# local-20260719) so the GRUB boot-menu entry can show the exact version being
# installed, not just the rolling channel alias in IMAGE_REF. Same label build-iso
# step 5 uses to name the ISO file — read once here, reused there.
IMG_VERSION="$(podman inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$BASE_IMAGE" 2>/dev/null || true)"
# BASE_IMAGE's own commit (stamped by Containerfile.os's GIT_SHA build-arg) —
# the source commit the PACKAGED IMAGE was built from. Reported
# alongside ISO_GIT_SHA below since the two can legitimately differ (an ISO can be
# rebuilt with newer iso/ scripts against an older, already-published image).
IMG_GIT_SHA="$(podman inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$BASE_IMAGE" 2>/dev/null || true)"
# Commit of THIS svk repo checkout, i.e. the iso/ scripts assembling this ISO —
# distinct from IMG_GIT_SHA above. Stamped into the live environment as
# svk-os/iso-build-info.json (see iso/installer/build.sh).
ISO_GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"

# NOTE: no LUKS passphrase is generated or passed here. The disk-encryption
# passphrase is minted per-install in the kickstart's %pre (iso/installer/build.sh),
# unique per machine and wiped at first boot — so no shared secret is baked into the
# ISO and none is printed/saved by this build.
#
# STAFF_PASSWORD: interim placeholder for the baked `staff` login, overridable per
# build (the kickstart expires it at first login either way). See the note in
# iso/installer/build.sh; the real fix is the USB provisioning config.
#
# ADMIN_PASSWORD: same deal for the `admin` operator. sysusers creates admin with
# a locked password, so before this every polkit admin prompt at the GUI was
# unanswerable; the kickstart's %post sets one. Deliberately NOT expired — an
# expired password fails PAM account management and breaks polkit all over again.
INSTALLER_IMAGE="localhost/svk-os-installer:latest"
podman build \
    --cap-add sys_admin --security-opt label=disable \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg IMAGE_REF="$IMAGE_REF" \
    --build-arg STAFF_PASSWORD="${STAFF_PASSWORD:-}" \
    --build-arg ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" \
    --build-arg VERSION="$IMG_VERSION" \
    --build-arg ISO_GIT_SHA="$ISO_GIT_SHA" \
    -t "$INSTALLER_IMAGE" \
    -f "${REPO_ROOT}/iso/installer/Containerfile" \
    "$REPO_ROOT"

# --- 3. Fetch Titanoboa (pinned) ------------------------------------------------
BUILD_DIR="${REPO_ROOT}/iso/.build"
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
# main.sh escalates its one `podman run` with `sudo`, unconditionally and in code
# we don't control — which would push us back into root's storage, where the
# installer image we just built rootlessly does not exist. Drop the escalation from
# our pinned local copy. The pattern matches whatever command follows `sudo`, so an
# iso/.build/ left over from an older checkout — where this patch rewrote the line
# to `sudo "$PODMAN" run` — is fixed too rather than skipped (the clone above only
# runs when main.sh is already missing). No-op once patched.
sed -i -E 's@sudo +[^ ]+ run@podman run@' "${BUILD_DIR}/main.sh"
# Fail loudly rather than silently building as root if a TITANOBOA_REF bump moves
# that line — a patch that stops matching is exactly how sudo would creep back.
if grep -qE '(^|[[:space:]])sudo[[:space:]]' "${BUILD_DIR}/main.sh"; then
    echo "titanoboa main.sh still escalates with sudo — the de-sudo patch is stale" >&2
    exit 1
fi

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
# Same user, same store: main.sh's `--mount type=image` finds the installer image
# built in step 2 directly. The ISO it writes is owned by us, so there is nothing
# to chown afterwards.
cd "$BUILD_DIR"
iso_path="$(env TITANOBOA_CTR_IMAGE="$INSTALLER_IMAGE" ./main.sh)"

# --- 5. Collect the ISO ----------------------------------------------------------
# Name the ISO after the exact image version it targets (the image.version label /
# os-release IMAGE_VERSION, e.g. 1-20260718) so the ISO, the image tag and os-release
# all report one matching version. Local dev images may carry none -> fall back to date.
img_ver="$IMG_VERSION"
[ -n "$img_ver" ] || img_ver="$(date +%Y%m%d)"
out="${REPO_ROOT}/iso/svk-os-${img_ver}.iso"
mv "$iso_path" "$out"

# Provenance sidecar next to the ISO — full build metadata in one readable file that
# rides along in the CI artifact (see .github/workflows/iso.yml) so an ISO can be
# identified without booting it or unsquashing it. Superset of what's baked inside
# the ISO's live env (svk-os/iso-build-info.json) and inside the installed image
# (svk-os/image-info.json). Contains NO secret — the per-install LUKS passphrase is
# minted at install time, not here. Documented in iso/README.md ("Build metadata").
info_file="${out%.iso}.build-info.json"
cat >"$info_file" <<EOF
{
  "roles": ["lab", "staff"],
  "channel": "${channel}",
  "image-ref": "${IMAGE_REF}",
  "image-version": "${IMG_VERSION:-}",
  "packaged-image-commit": "${IMG_GIT_SHA:-}",
  "iso-scripts-commit": "${ISO_GIT_SHA:-}",
  "iso-file": "$(basename "$out")",
  "built-at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo "SUCCESS: ${out}"
echo
echo "  Packaged image commit (svk-os):   ${IMG_GIT_SHA:-<none>}"
echo "  iso/ scripts commit (this build): ${ISO_GIT_SHA:-<none>}"
echo "  Build metadata sidecar:           ${info_file}"
echo
echo "  Disk encryption: the LUKS passphrase is generated per-install (nothing secret"
echo "  in this ISO). Each machine shows its own one-time recovery key on first boot —"
echo "  photograph it during provisioning. For a machine with NO TPM, capture the"
echo "  one-time passphrase from the installer console before it reboots"
echo "  (Ctrl+Alt+F3, then: cat /tmp/svk-luks-bootstrap)."
