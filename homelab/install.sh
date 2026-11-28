#!/usr/bin/env bash
# Cài script và unit vào homeserver. Chạy lại được nhiều lần (idempotent).
# KHÔNG bật timer nào — mỗi timer được bật ở giai đoạn tương ứng trong README.
# KHÔNG ghi đè /etc/homelab/*.env đã có.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Chạy bằng sudo." >&2; exit 1; }
SRC=$(dirname "$(readlink -f "$0")")

install -d -m 0755 /opt/homelab/bin
install -d -m 0700 /etc/homelab /var/lib/homelab
install -d -m 0750 /var/log/homelab
install -m 0755 "$SRC"/bin/*.sh /opt/homelab/bin/

[[ -f /etc/homelab/homelab.env ]] || install -m 0644 "$SRC/config/homelab.env.example" /etc/homelab/homelab.env
[[ -f /etc/homelab/secrets.env ]] || install -m 0600 "$SRC/config/secrets.env.example" /etc/homelab/secrets.env
install -m 0644 "$SRC/config/excludes.txt" "$SRC/config/restic-excludes.txt" /etc/homelab/
install -m 0644 "$SRC/config/logrotate-homelab" /etc/logrotate.d/homelab

install -m 0644 "$SRC"/systemd/*.service "$SRC"/systemd/*.timer "$SRC"/systemd/*.path /etc/systemd/system/
install -d /etc/systemd/system/docker.service.d
install -m 0644 "$SRC/systemd/docker.service.d/10-homelab-remote-fs.conf" /etc/systemd/system/docker.service.d/
systemctl daemon-reload

echo "Đã cài vào /opt/homelab và /etc/systemd/system."
echo "Chưa bật timer nào. Tiếp theo: điền /etc/homelab/homelab.env và secrets.env, rồi làm theo README."
grep -nE '^[A-Z_]+=.*CHANGE_ME' /etc/homelab/homelab.env || echo "Không còn giá trị CHANGE_ME nào."
