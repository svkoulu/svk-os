#!/usr/bin/bash
# build.staff.sh — staff desktop. Almost nothing on top of svk-base: normal login,
# no kiosk, no skel reset.
#
# On the raw Silverblue base there is no Distrobox/Homebrew to strip (unlike the
# old `FROM bluefin` build), so this is effectively a no-op today — kept as the
# hook for any future staff-only build step. The staff login account is created at
# install time by the complete kickstart in iso/installer/build.sh (currently a
# baked placeholder `staff` account; the per-site USB provisioning config replaces
# it later) — the staff ISO installs with no manual steps. Staff install their own
# apps with `flatpak install --user` (persists across image updates), and the
# shared fleet apps are baked into the staff ISO by Titanoboa.
set -euo pipefail

: # nothing to do yet
