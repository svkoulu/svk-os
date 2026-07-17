#!/usr/bin/bash
# 30-users.sh — admin operator account perms.
#
# The `admin` account itself is declared DECLARATIVELY via
# files/base/usr/lib/sysusers.d/svk-admin.conf (created at boot by
# systemd-sysusers, not baked into /etc/passwd — `bootc container lint` requires
# this). Its home is created by tmpfiles.d/svk-admin.conf, its keys come from
# ssh/authorized_keys.d/admin, and sshd hardening lives in sshd_config.d/.
#
# The only build-time step left is fixing the sudoers file mode: COPY lands it
# 0644, but sudo/visudo require 0440 or they ignore it.
set -euo pipefail

chmod 0440 /etc/sudoers.d/10-svk-admin
