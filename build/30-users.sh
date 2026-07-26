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
# exactly what the original value (980, colliding with group `power`) did, giving
# a different admin uid on every machine. Silent, so check it loudly here.
#
# 1000 is the first regular-user id, so it is free in any sane base — the real
# risk for this value is at RUNTIME, not build time: anything that creates a user
# before sysusers runs takes 1000 and pushes admin onto a fallback id. That is why
# both kickstarts pin their own accounts to 1001/1002 explicitly (uid AND gid);
# see iso/installer/build.sh.
SVK_ADMIN_ID=1000
if getent passwd "$SVK_ADMIN_ID" >/dev/null 2>&1 || getent group "$SVK_ADMIN_ID" >/dev/null 2>&1; then
    echo "ERROR: uid/gid ${SVK_ADMIN_ID} is taken in the base image —" \
         "systemd-sysusers would silently give admin a different, per-machine id." >&2
    echo "       Pick a free id and change it in files/os/usr/lib/sysusers.d/svk-admin.conf" >&2
    echo "       and here, and re-check the kickstarts' uids in iso/installer/build.sh." >&2
    exit 1
fi

chmod 0440 /etc/sudoers.d/10-svk-admin
