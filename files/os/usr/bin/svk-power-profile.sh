#!/usr/bin/bash
# svk-power-profile.sh — match the power profile to the power source.
#
#   on battery -> power-saver
#   on AC      -> balanced
#
# Run at boot (svk-power-profile.service) and on every AC plug/unplug (udev rule
# 99-svk-power-profile.rules).
#
# The profile is set over the net.hadess.PowerProfiles D-Bus API rather than with
# `powerprofilesctl`, because Fedora 44 Silverblue does NOT ship
# power-profiles-daemon: it ships tuned-ppd, which implements the same D-Bus
# interface (mapping power-saver -> the powersave tuned profile) but installs no
# powerprofilesctl binary. This script called that binary and, because the call
# was error-suppressed, did nothing at all on every machine for as long as the
# rebuild has existed — found 2026-08-19 by ci/verify-image.sh, which now asserts
# that every command a shipped script calls is actually installed.
#
# busctl is systemd's own, so it cannot go missing the way a CLI from a
# separate package can.
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

# Don't fail the udev-triggered unit if the daemon isn't up yet — it is retried
# on the next plug/unplug and at boot. But say so in the journal: silent failure
# here is exactly how the powerprofilesctl breakage survived unnoticed.
if busctl set-property net.hadess.PowerProfiles /net/hadess/PowerProfiles \
        net.hadess.PowerProfiles ActiveProfile s "$profile" 2>/dev/null; then
    echo "svk-power-profile: set ${profile} (on_ac=${on_ac})"
else
    echo "svk-power-profile: could not set ${profile} — is tuned-ppd.service running?" >&2
fi
