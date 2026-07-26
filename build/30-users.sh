#!/usr/bin/bash
# 30-users.sh — admin operator account perms.
#
# The `admin` account itself is declared DECLARATIVELY via
# files/os/usr/lib/sysusers.d/svk-admin.conf (created at boot by
# systemd-sysusers, not baked into /etc/passwd — `bootc container lint` requires
# this). Its home is created by tmpfiles.d/svk-admin.conf, its keys come from
# ssh/authorized_keys.d/admin, and sshd hardening lives in sshd_config.d/.
#
# The only build-time step left is fixing the sudoers file mode: COPY lands it
# 0644, but sudo/visudo require 0440 or they ignore it.
set -euo pipefail

# Assert admin's declared id is still free in the base image. A `u admin <id>`
# entry claims that number as BOTH uid and gid, so a collision on EITHER makes
# sysusers discard it and allocate something arbitrary at first boot — which is
# exactly what the previous value (980, colliding with group `power`) did, giving
# a different admin uid on every machine. Silent, so check it loudly here.
SVK_ADMIN_ID=480
if getent passwd "$SVK_ADMIN_ID" >/dev/null 2>&1 || getent group "$SVK_ADMIN_ID" >/dev/null 2>&1; then
    echo "ERROR: uid/gid ${SVK_ADMIN_ID} is taken in the base image —" \
         "systemd-sysusers would silently give admin a different, per-machine id." >&2
    echo "       Pick a free id and change it in files/os/usr/lib/sysusers.d/svk-admin.conf" >&2
    echo "       and here. 191-958 was empty as of Silverblue 44." >&2
    exit 1
fi

chmod 0440 /etc/sudoers.d/10-svk-admin
