#!/usr/bin/bash

set -euo pipefail

###############################################################################
# Image Info Generation
###############################################################################
# Generates /usr/share/ublue-os/image-info.json and customizes /usr/lib/os-release.
# This script is bluefin-pattern: each consumer provides its own branding.
#
# Required env vars (set as ARGs in Containerfile):
#   IMAGE_NAME          - Image name (e.g. finpilot, my-custom-os)
#   IMAGE_VENDOR        - Image vendor/owner (e.g. github username or org)
#   UBLUE_IMAGE_TAG     - Image tag/stream (e.g. stable, testing, latest)
#   BASE_IMAGE_NAME     - Base image name (e.g. silverblue)
#   FEDORA_MAJOR_VERSION - Fedora version (e.g. 42)
#   VERSION             - Full version string (e.g. stable-42.20250531)
#   SHA_HEAD_SHORT      - Short git SHA (optional, for dev builds)
###############################################################################

# Branding — customize these for your image
IMAGE_PRETTY_NAME="${IMAGE_PRETTY_NAME:-SVK OS}"
IMAGE_LIKE="${IMAGE_LIKE:-fedora}"
HOME_URL="${HOME_URL:-https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}}"
DOCUMENTATION_URL="${DOCUMENTATION_URL:-https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}/blob/main/README.md}"
SUPPORT_URL="${SUPPORT_URL:-https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}/issues}"
BUG_REPORT_URL="${BUG_REPORT_URL:-https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}/issues/new}"

# Paths
IMAGE_INFO="/usr/share/ublue-os/image-info.json"
OS_RELEASE="/usr/lib/os-release"

# Derive image flavor from name
if [[ "${IMAGE_NAME}" =~ nvidia ]]; then
	IMAGE_FLAVOR="nvidia"
else
	IMAGE_FLAVOR="main"
fi

# Image ref (used by bootc for upgrade source)
IMAGE_REF="ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"

###############################################################################
# Write image-info.json
###############################################################################
mkdir -p /usr/share/ublue-os
cat >"${IMAGE_INFO}" <<EOF
{
  "image-name": "${IMAGE_NAME}",
  "image-flavor": "${IMAGE_FLAVOR}",
  "image-vendor": "${IMAGE_VENDOR}",
  "image-ref": "${IMAGE_REF}",
  "image-tag": "${UBLUE_IMAGE_TAG}",
  "base-image-name": "${BASE_IMAGE_NAME}",
  "fedora-version": "${FEDORA_MAJOR_VERSION}"
}
EOF

echo "Wrote ${IMAGE_INFO}"
echo "  image-name: ${IMAGE_NAME}"
echo "  image-flavor: ${IMAGE_FLAVOR}"
echo "  image-vendor: ${IMAGE_VENDOR}"

###############################################################################
# Customize /usr/lib/os-release
###############################################################################
# The Silverblue base already sets VARIANT_ID / PRETTY_NAME / NAME, so we UPSERT
# svk's identity (replace the key if present, append if not) rather than the
# finpilot original's append-only-if-VARIANT_ID-absent (which no-ops on Silverblue).
if [[ -f "${OS_RELEASE}" ]]; then
	OS_VERSION="${VERSION:-${UBLUE_IMAGE_TAG}}"

	set_os_release() {
		local key="$1" val="$2"
		if grep -q "^${key}=" "${OS_RELEASE}"; then
			sed -i "s|^${key}=.*|${key}=\"${val}\"|" "${OS_RELEASE}"
		else
			printf '%s="%s"\n' "${key}" "${val}" >>"${OS_RELEASE}"
		fi
	}

	set_os_release PRETTY_NAME       "${IMAGE_PRETTY_NAME}"
	set_os_release NAME              "${IMAGE_NAME}"
	set_os_release VARIANT_ID        "${IMAGE_FLAVOR}"
	set_os_release IMAGE_ID          "${IMAGE_NAME}"
	set_os_release IMAGE_VERSION     "${OS_VERSION}"
	set_os_release HOME_URL          "${HOME_URL}"
	set_os_release DOCUMENTATION_URL "${DOCUMENTATION_URL}"
	set_os_release SUPPORT_URL       "${SUPPORT_URL}"
	set_os_release BUG_REPORT_URL    "${BUG_REPORT_URL}"

	echo "Customized ${OS_RELEASE}"
fi
