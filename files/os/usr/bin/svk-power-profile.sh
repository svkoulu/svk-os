#!/usr/bin/bash
# svk-power-profile.sh — match the power profile to the power source.
#
#   on battery -> power-saver
#   on AC      -> balanced
#
# Run at boot (svk-power-profile.service) and on every AC plug/unplug (udev rule
# 99-svk-power-profile.rules). power-profiles-daemon exposes the profiles; we
# just flip between two that always exist.
set -euo pipefail

shopt -s nullglob
on_ac=0
have_mains=0
for ps in /sys/class/power_supply/*; do
    [ "$(cat "$ps/type" 2>/dev/null || true)" = "Mains" ] || continue
    have_mains=1
    [ "$(cat "$ps/online" 2>/dev/null || echo 0)" = "1" ] && on_ac=1
done

# A machine with no AC adapter at all (desktop / VM) has nothing to save power
# from — treat it as plugged in.
[ "$have_mains" = 0 ] && on_ac=1

if [ "$on_ac" = 1 ]; then
    profile=balanced
else
    profile=power-saver
fi

# Don't fail the udev-triggered unit if ppd isn't up yet; it'll be re-run.
powerprofilesctl set "$profile" 2>/dev/null || exit 0
echo "svk-power-profile: set ${profile} (on_ac=${on_ac})"
