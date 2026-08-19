#!/usr/bin/env bash
# verify-image.sh — tier 1 verification: static checks against a built svk-os image.
#
# This does NOT prove a machine boots, installs or logs in. It proves that the
# things which most often stop those from happening are present and well-formed:
# a unit that will not parse, a script that is not executable, a dconf db that
# compiled empty, a helper binary the base image quietly stopped shipping.
# Booting an installed machine is tier 2 (see
# tasks/todo/…-tier2-boot-smoke-test.md); this is the half that can run on every
# push, in CI, on a runner with no KVM.
#
# It exists because the driving risk of this repo is silence: a pipeline that
# breaks without telling anyone, a machine that installs and comes up inert.
# Every check below is either something we have already been bitten by or
# something whose failure mode is invisible until a room full of laptops is
# wrong.
#
# Usage: ci/verify-image.sh [image-ref]        (default: localhost/svk-os:latest)
#
# Env:
#   SVK_EXPECT_LOCKDOWN=1|0   what the per-account app lockdown should be in this
#                             image. Default: the ARG SVK_LOCKDOWN default parsed
#                             out of Containerfile.os, so the check asserts
#                             "image matches source intent" rather than a
#                             hardcoded expectation — and a bring-up build is
#                             reported loudly instead of passing quietly.

# Most checks below run INSIDE the image via `run ... bash -c '...'`, so the
# single quotes are deliberate: those expressions must expand in the container,
# not here. Silence SC2016 for the file rather than annotating twenty lines.
# shellcheck disable=SC2016

set -euo pipefail

IMAGE="${1:-localhost/svk-os:latest}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="/usr/lib/systemd/system-preset/50-svk.preset"
fails=0

# Preflight. Without this a missing podman or a missing image makes every check
# below fail identically to a real defect — a screenful of confident FAILs that
# mean nothing. A verification tool that cannot tell "broken" from "couldn't
# look" is worse than none, so refuse to run instead.
command -v podman >/dev/null || {
    echo "podman not found — cannot verify. Tooling problem, not an image problem." >&2
    exit 127
}
podman image exists "$IMAGE" || {
    echo "image not present locally: $IMAGE" >&2
    echo "build it first (just build-os) or pull it." >&2
    exit 127
}
podman run --rm --entrypoint "" "$IMAGE" true >/dev/null 2>&1 || {
    echo "cannot run $IMAGE at all — verification cannot proceed." >&2
    exit 127
}

run() { podman run --rm --entrypoint "" "$IMAGE" "$@"; }

# A failing check that does not say why sends you reading the image by hand, so
# capture the output and print it indented underneath.
check() {
    local desc="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then
        printf '  ok    %s\n' "$desc"
    else
        printf '  FAIL  %s\n' "$desc"
        [ -n "$out" ] && printf '        | %s\n' "${out//$'\n'/$'\n'        | }"
        fails=$(( fails + 1 ))
    fi
}

# Passes when the command FAILS — for asserting absence.
check_not() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  FAIL  %s\n' "$desc"
        fails=$(( fails + 1 ))
    else
        printf '  ok    %s\n' "$desc"
    fi
}

echo "verifying $IMAGE"

# The units the fleet cannot lose. Each is checked twice, and the duplication is
# the point — see the header of files/os/usr/lib/systemd/system-preset/50-svk.preset:
#
#   is-enabled  the /etc symlink, which is what holds up a machine that has
#               already booted once and takes updates.
#   preset      the /usr preset line, which is what holds up the FIRST boot of a
#               fresh /etc — an Anaconda install. Without it, first-boot preset
#               policy deletes the symlink and the machine comes up inert:
#               reproduced against a built image on 2026-08-19, 10 of 11 units
#               off, sshd and tailscaled among them.
echo "-- unit enablement"
UNITS=(
    sshd.service
    avahi-daemon.service
    svk-claim-hostname.service
    tailscaled.service
    svk-tailscale-enroll.service
    svk-luks-tpm-enroll.service
    bootc-fetch-apply-updates.timer
    svk-flatpak-update.timer
    svk-power-profile.service
    reset-opilas-home.service
    svk-bluetooth-default-off.service
)
for unit in "${UNITS[@]}"; do
    check "enabled: $unit" run systemctl --root=/ is-enabled "$unit"
    check "preset:  $unit" run grep -qx "enable $unit" "$PRESET"
done

# The two lists above are written in two files by hand, so assert they cannot
# drift: every `systemctl enable` in build/20-services.sh must have a preset
# line, and every preset line must have a `systemctl enable`. Source-tree check
# (both files are in the checkout at build time), which is why it can name the
# missing line precisely.
echo "-- enable/preset lists agree (source tree)"
check "every build/20-services.sh enable has a preset line" bash -c '
    set -euo pipefail
    root="$1"; preset="$2"
    missing=""
    while read -r u; do
        grep -qx "enable $u" "$root/files/os$preset" || missing="$missing $u"
    done < <(grep -oP "^systemctl enable \K\S+" "$root/build/20-services.sh")
    [ -z "$missing" ] || { echo "not in 50-svk.preset:$missing"; exit 1; }
' _ "$REPO_ROOT" "$PRESET"
check "every preset enable line has a build/20-services.sh enable" bash -c '
    set -euo pipefail
    root="$1"; preset="$2"
    missing=""
    while read -r u; do
        grep -qx "systemctl enable $u" "$root/build/20-services.sh" || missing="$missing $u"
    done < <(grep -oP "^enable \K\S+" "$root/files/os$preset")
    [ -z "$missing" ] || { echo "not in build/20-services.sh:$missing"; exit 1; }
' _ "$REPO_ROOT" "$PRESET"

# The regression test for the bug the preset file exists to prevent. Applies the
# base image's own preset policy to a throwaway container exactly as systemd
# does on the first boot of a fresh /etc, and asserts every unit survives it.
# Stronger than the grep above: it catches an ordering mistake (Silverblue
# disables sshd.service in 81-desktop.preset, so anything numbered above 81
# loses) which a per-line grep cannot see.
echo "-- first-boot preset policy simulation"
check "all units survive systemctl preset-all" run bash -c '
    systemctl preset-all --root=/ >/dev/null 2>&1
    bad=""
    for u in "$@"; do
        systemctl --root=/ is-enabled "$u" >/dev/null 2>&1 || bad="$bad $u"
    done
    [ -z "$bad" ] || { echo "disabled by preset policy:$bad"; exit 1; }
' _ "${UNITS[@]}"

# Every unit we ship must parse. A typo here is a machine that boots without the
# thing the unit was for, and nothing says so.
echo "-- units and scripts"
check "units parse" run bash -c '
    systemd-analyze verify /etc/systemd/system/svk-*.service \
        /etc/systemd/system/svk-*.timer /etc/systemd/system/reset-opilas-home.service 2>&1 |
        grep -vE "network-online.target|Failed to resolve|systemd-networkd" | grep . && exit 1
    exit 0
'
# Ship a script without +x and the unit fails at ExecStart with a message nobody
# is watching for.
check "svk helpers are executable" run bash -c '
    bad=""
    for f in /usr/libexec/svk/* /usr/bin/svk-*.sh /usr/bin/reset-opilas-home.sh; do
        [ -x "$f" ] || bad="$bad $f"
    done
    [ -z "$bad" ] || { echo "not executable:$bad"; exit 1; }
'
# COPY carries the build context's modes and git records only the exec bit, so a
# CI runner with a loose umask can ship world-writable units without any local
# build ever showing it.
check "nothing we ship is group- or world-writable" run bash -c '
    found="$(find /etc/svk /etc/systemd/system /etc/polkit-1/rules.d /etc/sudoers.d \
                  /etc/dconf /usr/libexec/svk /usr/lib/sysusers.d \
                  /usr/lib/systemd/system-preset \
                  -perm /022 ! -type l -print 2>/dev/null)"
    [ -z "$found" ] || { echo "$found"; exit 1; }
'

# The lockdown is a compiled binary db, and dconf compiles an empty or unparsable
# source directory into a valid, empty db without failing — so "the file exists"
# proves nothing. Assert it carries an actual lock, which is what makes the
# difference between a locked-down kiosk and an ordinary desktop.
echo "-- dconf lockdown"
check "kiosk profile exists"        run test -s /etc/dconf/profile/kiosk
check "user profile exists"         run test -s /etc/dconf/profile/user
check "kiosk db compiled non-empty" run bash -c 'test -s /etc/dconf/db/kiosk'
check "local db compiled non-empty" run bash -c 'test -s /etc/dconf/db/local'
check "kiosk db actually carries the lockdown keys" run bash -c '
    for key in $(grep -oP "^/\S+" /etc/dconf/db/kiosk.d/locks/00-svk-locks | head -5); do
        grep -aq "${key#/}" /etc/dconf/db/kiosk || { echo "missing from compiled db: $key"; exit 1; }
    done
'
# The kiosk db is selected per account via DCONF_PROFILE, so the fleet-wide
# profile must NOT be the kiosk one — that would apply the lockdown to admin and
# staff too (CLAUDE.md: never make kiosk behaviour machine-wide).
check_not "user profile does not select the kiosk db" \
    run grep -q "user-db:kiosk\|system-db:kiosk" /etc/dconf/profile/user

# Update policy. --apply reboots the machine the moment an update stages, which
# on a lab machine means mid-lesson.
echo "-- update policy"
check "bootc update drop-in resets ExecStart" \
    run grep -qx "ExecStart=" /etc/systemd/system/bootc-fetch-apply-updates.service.d/10-svk-no-force-apply.conf
check_not "desktop update path does not use --apply" run bash -c '
    grep -h "^ExecStart=." /etc/systemd/system/bootc-fetch-apply-updates.service.d/*.conf |
        grep -q -- "--apply"
'
check "update timer is on the weekly schedule" \
    run grep -q "^OnCalendar=Mon" /etc/systemd/system/bootc-fetch-apply-updates.timer.d/10-svk-schedule.conf
check "update timer keeps a randomized delay" \
    run grep -q "^RandomizedDelaySec=" /etc/systemd/system/bootc-fetch-apply-updates.timer.d/10-svk-schedule.conf

# Signing. A machine only accepts an image signed with this key; if the public
# half is missing or does not match the repo's, every update is rejected fleet-wide
# and the only fix is physical.
echo "-- signing and update origin"
check "cosign public key is baked in" run test -s /etc/pki/containers/svk-cosign.pub
check "baked key matches the repo's cosign.pub" bash -c '
    diff <(podman run --rm --entrypoint "" "$1" cat /etc/pki/containers/svk-cosign.pub) "$2/cosign.pub"
' _ "$IMAGE" "$REPO_ROOT"
check "policy.json is valid JSON" run bash -c 'jq -e . /etc/containers/policy.json >/dev/null'
check "policy.json requires a signature for our namespace" run bash -c '
    jq -e ".transports.docker[\"ghcr.io/svkoulu\"][0].type == \"sigstoreSigned\"" \
        /etc/containers/policy.json >/dev/null
'
check "policy.json points at the baked key" run bash -c '
    jq -e ".transports.docker[\"ghcr.io/svkoulu\"][0].keyPath == \"/etc/pki/containers/svk-cosign.pub\"" \
        /etc/containers/policy.json >/dev/null
'
check "registries.d gives our namespace a signature store" \
    run test -s /etc/containers/registries.d/ghcr-svk.yaml

# Identity. The version string has to be the same in all three places or an
# operator reading one of them is reading a lie.
echo "-- identity and branding"
check "os-release is stamped svk-os" run grep -qx 'IMAGE_ID="svk-os"' /usr/lib/os-release
check "image-info.json is valid JSON" run bash -c 'jq -e . /usr/share/svk-os/image-info.json >/dev/null'
check "image-info.json version == os-release IMAGE_VERSION" run bash -c '
    a="$(jq -r .version /usr/share/svk-os/image-info.json)"
    b="$(. /usr/lib/os-release; echo "$IMAGE_VERSION")"
    [ "$a" = "$b" ] || { echo "image-info.json=$a os-release=$b"; exit 1; }
'
check "PRETTY_NAME carries the version" run bash -c '
    . /usr/lib/os-release
    case "$PRETTY_NAME" in *"$IMAGE_VERSION"*) ;; *) echo "PRETTY_NAME=$PRETTY_NAME"; exit 1 ;; esac
'

# The fixed id map. sysusers silently allocates a different uid on collision, and
# the AccountsService drop-in that hides admin from the greeter is keyed to it —
# change one without the other and admin reappears in the login screen.
echo "-- accounts"
check "admin is pinned to uid 1000" run grep -qE '^u[[:space:]]+admin[[:space:]]+1000' /usr/lib/sysusers.d/svk-admin.conf
check "admin is hidden from the greeter" run grep -q "SystemAccount=true" /etc/tmpfiles.d/svk-admin.conf
check "admin has an authorized key" run test -s /etc/ssh/authorized_keys.d/admin
check "sshd is key-only" run grep -qi "^PasswordAuthentication no" /etc/ssh/sshd_config.d/10-svk-hardening.conf

# Binaries our own scripts call. These come from the base image, not from us, so
# a base bump can remove one and nothing fails until the script runs on a machine
# — where every one of these scripts swallows its own errors by design.
echo "-- helper binaries our scripts depend on"
check "tailscale present"           run test -x /usr/bin/tailscale
check "avahi-daemon present"        run test -x /usr/sbin/avahi-daemon
check "flatpak present"             run test -x /usr/bin/flatpak
check "dconf present"               run test -x /usr/bin/dconf
check "jq present (svk helpers)"    run test -x /usr/bin/jq
check "qrencode present (LUKS recovery key QR)" run test -x /usr/bin/qrencode
check "systemd-cryptenroll present (TPM2 enrollment)" run test -x /usr/bin/systemd-cryptenroll
check "tpm2_getcap present (tpm2-capable probe)" run test -x /usr/bin/tpm2_getcap
# Every binary svk-power-profile.sh, the hostname claim and the enroll scripts
# actually invoke, taken from the scripts themselves rather than a list kept by
# hand — the power-profile script called powerprofilesctl for a month after
# Fedora 44 replaced power-profiles-daemon with tuned-ppd, and silently did
# nothing on every machine.
check "commands called by shipped scripts exist" run bash -c '
    missing=""
    for cmd in $(grep -hoE "^[[:space:]]*(powerprofilesctl|tuned-adm|busctl|nmcli|rfkill|hostnamectl|tailscale|jq|curl|qrencode|systemd-cryptenroll|cryptsetup|dconf|flatpak|bootc)\b" \
                    /usr/bin/svk-*.sh /usr/bin/reset-opilas-home.sh /usr/libexec/svk/* 2>/dev/null |
                 tr -d "[:blank:]" | sort -u); do
        command -v "$cmd" >/dev/null || missing="$missing $cmd"
    done
    [ -z "$missing" ] || { echo "called but not installed:$missing"; exit 1; }
'

# Removals. The RPM Firefox shipping alongside the Flatpak gives two browsers
# with two different policy files, and only one of them has uBlock Origin.
echo "-- removals"
check_not "RPM firefox is gone"     run test -e /usr/bin/firefox
check_not "gnome-tour is gone"      run test -e /usr/bin/gnome-tour
check_not "malcontent-control gone" run test -e /usr/bin/malcontent-control

# mDNS is how the whole fleet is addressed on the LAN — lab machines never join
# the tailnet.
echo "-- name resolution"
check "nsswitch resolves .local via mdns" run grep -qE '^hosts:.*mdns' /etc/nsswitch.conf

# The per-account app lockdown. Expectation comes from Containerfile.os's own ARG
# default so this asserts the image matches the source, and a bring-up build is
# stated out loud rather than passing silently.
echo "-- per-account app lockdown"
expect_lockdown="${SVK_EXPECT_LOCKDOWN:-$(grep -oP '^ARG SVK_LOCKDOWN="\K[01]' "$REPO_ROOT/Containerfile.os" || echo 1)}"
if [ "$expect_lockdown" = 1 ]; then
    for bin in /usr/bin/ptyxis /usr/bin/gnome-disks /usr/bin/gnome-system-monitor; do
        check "restricted to wheel: $bin" run bash -c "
            [ \"\$(stat -c '%a %G' $bin)\" = '750 wheel' ] || { stat -c '%a %G' $bin; exit 1; }
        "
    done
else
    echo "  WARN  SVK_LOCKDOWN=0 — the admin apps are NOT restricted in this image."
    echo "        This is the bring-up setting (Containerfile.os). A fleet ISO built"
    echo "        from it hands every student a terminal. Set it back to 1."
fi

echo
if [ "$fails" -gt 0 ]; then
    echo "FAILED: $fails check(s)"
    exit 1
fi
echo "all checks passed"
