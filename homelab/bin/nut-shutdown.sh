#!/usr/bin/env bash
# GIAI ĐOẠN 2 — Được upsmon gọi (SHUTDOWNCMD) khi pin UPS xuống ngưỡng thấp.
# Thứ tự bắt buộc: dừng container → gỡ NFS → hẹn giờ tắt NAS → tắt server.
# Server phải tắt TRƯỚC NAS vì sau cutover Immich ghi dữ liệu qua NFS lên NAS.
# Chạy thử an toàn (không tắt gì): nut-shutdown.sh --dry-run

. "$(dirname "$(readlink -f "$0")")/lib.sh"
load_config optional

DRY=0
[[ ${1:-} == --dry-run ]] && DRY=1
do_() { if ((DRY)); then log "[dry-run] $*"; else "$@"; fi; }

log "UPS sắp hết pin — bắt đầu tắt máy có thứ tự (dry-run=$DRY)"
tg_send "🔋 UPS pin yếu: đang tắt homeserver và NAS theo thứ tự." &

# 1. Dừng mọi container (Immich, Postgres...) để dữ liệu được ghi xong
ids=$(docker ps -q 2>/dev/null)
[[ -n $ids ]] && do_ timeout 120 docker stop -t 60 $ids

# 2. Gỡ các mount NFS (thử bình thường, rồi lazy)
for m in ${PRIMARY:-/srv/nas} ${NAS_MOUNT:-/mnt/nas-data} /mnt/nas-ugreen; do
  if mountpoint -q "$m"; then
    do_ sync
    do_ umount "$m" || do_ umount -l "$m"
  fi
done

# 3. Hẹn NAS tự tắt sau 2 phút (cần sudo không mật khẩu cho lệnh shutdown trên NAS).
#    Nếu không được, NAS sẽ tự tắt theo cài đặt UPS mạng trong UGOS (nếu đã cấu hình).
if [[ -n ${NAS_IP:-} ]]; then
  if ((DRY)); then
    log "[dry-run] ssh $NAS_SSH_USER@$NAS_IP sudo -n /sbin/shutdown -h +2"
    nas_ssh 'sudo -n -l /sbin/shutdown >/dev/null 2>&1 && echo "sudo shutdown: OK" || echo "sudo shutdown: KHÔNG CÓ QUYỀN"' \
      | while read -r l; do log "$l"; done
  else
    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 "$NAS_SSH_USER@$NAS_IP" 'sudo -n /sbin/shutdown -h +2' \
      && log "Đã hẹn NAS tắt sau 2 phút" || log "Không ra lệnh tắt NAS được qua SSH"
  fi
fi

wait
# 4. Tắt server
do_ /sbin/shutdown -h now
