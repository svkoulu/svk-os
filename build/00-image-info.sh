#!/usr/bin/bash
# 00-image-info.sh — brand svk-base's /usr/lib/os-release.
#
# Thin wrapper around the shared stamper shipped at /usr/libexec/svk/stamp-os-release
# (files/base/, already COPY'd to / before this runs). The derived images re-run that
# same stamper with their own identity. It writes both /usr/lib/os-release and
# /usr/share/svk-os/image-info.json (svk's own metadata file — same idea as ublue's
# image-info.json but under svk-os/, no ublue path/vendor). Fedora's version stays
# visible via the Silverblue base's own os-release (VERSION_ID / OSTREE_VERSION).
#
# Env (from Containerfile ARGs): IMAGE_NAME, IMAGE_VENDOR, VERSION.
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-svk-base}" \
IMAGE_VENDOR="${IMAGE_VENDOR:-svkoulu}" \
IMAGE_PRETTY_NAME="SVK OS" \
VERSION="${VERSION:-}" \
	/usr/libexec/svk/stamp-os-release
