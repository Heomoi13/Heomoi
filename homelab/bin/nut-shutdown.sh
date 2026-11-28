#!/usr/bin/env bash
# GIAI ĐOẠN 2 — Tắt máy có thứ tự khi mất điện (UPS CyberPower VP1600ELCD qua USB, NUT primary trên server).
#
# Luồng chuẩn (mất điện kéo dài):
#   ONBATT → upssched đếm 180 s → nut-upssched-cmd.sh (user nut) tạo /run/nut/homelab-fsd-request
#   → systemd homelab-ups-fsd.path → homelab-ups-fsd.service (root) chạy:  nut-shutdown.sh fsd
#        1. cờ bảo trì /run/homelab-maintenance (job giám sát không tự bật lại container)
#        2. dừng mọi container (Immich, Home Assistant, go2rtc, ...)
#        3. gỡ NFS /srv/nas và /mnt/nas-data  → không còn gì ghi lên NAS
#        4. upsmon -c fsd → NAS (NUT secondary) nhận FSD và tự tắt
#   → upsmon chờ NAS ngắt kết nối (HOSTSYNC) → chạy SHUTDOWNCMD:  nut-shutdown.sh final  → server tắt
#   → driver ra lệnh UPS cắt điện ổ cắm sau 60 s; có điện lưới lại → bật lại → server + NAS tự khởi động.
# Luồng dự phòng (pin yếu trước khi hết 180 s): upsmon tự FSD → "final" tự làm bước 1–3 nếu chưa làm.
#
# Lệnh: nut-shutdown.sh fsd|final [--dry-run]     (--dry-run: chỉ in các bước, không làm gì)

. "$(dirname "$(readlink -f "$0")")/lib.sh"
load_config optional

MODE=final DRY=0
for a in "$@"; do
  case $a in
    fsd|final) MODE=$a ;;
    --dry-run) DRY=1 ;;
    *) die "Dùng: $0 fsd|final [--dry-run]" ;;
  esac
done
((DRY)) || require_root

PRIMARY=${PRIMARY:-/srv/nas}
NAS_MOUNT=${NAS_MOUNT:-/mnt/nas-data}
PREPARED=/run/homelab-ups-prepared

do_() { if ((DRY)); then log "[dry-run] $*"; else "$@"; fi; }

prepare() {
  if [[ -f $PREPARED ]] && ((!DRY)); then
    log "Container và NFS đã được xử lý trước đó — bỏ qua."
    return 0
  fi
  log "Bước 1: đặt cờ bảo trì"
  ((DRY)) || echo "mất điện (UPS) từ $(date '+%F %T')" >/run/homelab-maintenance

  local ids
  ids=$(docker ps -q 2>/dev/null)
  log "Bước 2: dừng $(wc -w <<<"$ids") container"
  # shellcheck disable=SC2086
  [[ -n $ids ]] && do_ timeout 150 docker stop -t 60 $ids >/dev/null

  log "Bước 3: gỡ NFS"
  do_ sync
  local m
  for m in "$PRIMARY" "$NAS_MOUNT"; do
    if timeout 10 mountpoint -q "$m" 2>/dev/null; then
      do_ timeout 30 umount "$m" || do_ umount -l "$m"
    fi
  done
  ((DRY)) || touch "$PREPARED"
}

case $MODE in
  fsd)
    log "=== Mất điện kéo dài: tắt có thứ tự (dry-run=$DRY) ==="
    ((DRY)) || tg_send "🔌 Mất điện quá 3 phút — tắt có thứ tự: container → NFS → NAS → server."
    prepare
    log "Bước 4: gửi FSD — NAS tắt trước, server tắt sau"
    do_ "$(command -v upsmon || echo /usr/sbin/upsmon)" -c fsd
    ;;
  final)
    log "=== SHUTDOWNCMD: tắt server (dry-run=$DRY) ==="
    prepare
    do_ /sbin/shutdown -h +0
    ;;
esac
