#!/usr/bin/bash
# build.staff.sh — staff desktop. Almost nothing on top of svk-base: normal login,
# no kiosk, no skel reset.
#
# The staff login account is created at install time by the complete kickstart in
# iso/installer/build.sh (currently a baked placeholder `staff` account; the
# per-site USB provisioning config replaces it later) — the staff ISO installs
# with no manual steps. All flatpaks (shared fleet set baked by Titanoboa) are
# system-scope, same as student — see tasks/todo/…-fleet-update-cadence.md for
# why: staff never actually had a working `--user` install path (no terminal, no
# SSH, the old ujust recipe that offered it was unwired boilerplate), so this
# spec makes system-only the documented, enforced reality instead of an
# aspirational comment.
set -euo pipefail

echo "::group:: Remove gnome-software (no runtime flatpak-remote UI)"
# flatpak --user installs need zero privilege — no polkit gate the way system
# installs have — so the real backstop against a self-service install is "there's
# no UI capable of adding a remote or invoking flatpak install" on this account,
# not a permission check. Terminal (Ptyxis) and SSH are already closed off for
# staff (build/40-desktop.sh, admin-key-only sshd); removing gnome-software closes
# the one remaining avenue, consistent with the fleet having no runtime app-store
# path at all (flatpaks are baked into the ISO, not browsed/installed later).
if rpm -q gnome-software >/dev/null 2>&1; then
    dnf5 remove -y gnome-software
fi
echo "::endgroup::"
