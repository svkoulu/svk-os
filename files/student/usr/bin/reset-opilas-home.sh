#!/usr/bin/bash
# reset-opilas-home.sh — wipe /home/opilas back to a pristine /etc/skel.
#
# REVIEW: This is the trickiest piece in the whole repo. It is invoked by GDM
# PostSession (see /etc/gdm/PostSession/Default) which runs as root AFTER the
# opilas session tears down and BEFORE the next autologin. That ordering is
# what makes a plain rm+copy safe. Two things to keep an eye on:
#   1. Race: with autologin, GDM re-logs-in `opilas` immediately after logout.
#      PostSession runs synchronously in that gap, and we `systemctl start`
#      (blocking, not --no-block) so the reset finishes before relogin. If you
#      ever see a half-reset home, this ordering is the first suspect.
#   2. Safety guard: we refuse to run while an `opilas` session is still active,
#      so a mis-fire can never nuke a live session's files.
# An alternative design is a pure systemd unit bound to the session scope
# ending; PostSession was chosen because it is synchronous and dead simple.
set -euo pipefail

USER_NAME=opilas
USER_HOME="/home/${USER_NAME}"
SKEL=/etc/skel

# Guard: bail out if opilas is currently logged in anywhere.
if loginctl list-sessions --no-legend 2>/dev/null | grep -qw "$USER_NAME"; then
    echo "reset-opilas-home: ${USER_NAME} session still active, skipping." >&2
    exit 0
fi

# Also runs at boot (before the display manager) to CREATE the home the first
# time, since bootc doesn't persist a build-time /home. mkdir -p handles both
# "doesn't exist yet" and "exists, reset it".
mkdir -p "$USER_HOME"

# Clear the home directory contents (dotfiles included) without deleting the
# mountpoint itself, then repopulate from skel and fix ownership.
find "$USER_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -aT "$SKEL" "$USER_HOME"
chown -R "${USER_NAME}:${USER_NAME}" "$USER_HOME"
chmod 700 "$USER_HOME"

echo "reset-opilas-home: ${USER_HOME} reset to ${SKEL}."
