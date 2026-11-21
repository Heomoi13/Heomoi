#!/usr/bin/env bash
# GIAI ĐOẠN 1 — Sao lưu "mồi" hằng tuần: /srv/nas (HDD) → NAS:/volume1/data/homelab.
# Vừa là bản sao thứ 3, vừa là bản mồi để cutover (giai đoạn 4) chỉ phải chép phần chênh lệch.
# KHÔNG dùng --delete: đây là bản backup, file xoá nhầm trên server vẫn còn trên NAS.
# Tự dừng (không làm gì) khi dữ liệu gốc đã nằm trên NAS.

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars PRIMARY NAS_IP NAS_MAC NAS_MOUNT NAS_HOMELAB_SUBDIR NAS_META_SUBDIR DUMP_DIR

main() {
  take_lock nas-sync
  if is_nfs_mount "$PRIMARY"; then
    log "$PRIMARY đã là NFS (đã cutover). Seed không còn cần thiết — tắt timer homelab-seed."
    return 0
  fi
  mountpoint -q "$PRIMARY" || die "$PRIMARY chưa được mount — không chép thư mục rỗng."

  nas_wake
  nas_dest_ready || die "Đích $NAS_MOUNT/$NAS_HOMELAB_SUBDIR không sẵn sàng hoặc thiếu sentinel."

  "$(dirname "$(readlink -f "$0")")/immich-db-dump.sh" || log "Cảnh báo: dump DB thất bại, vẫn chép dữ liệu."

  log "rsync $PRIMARY/ → $NAS_MOUNT/$NAS_HOMELAB_SUBDIR/"
  rsync -aH --numeric-ids --partial --info=stats2 \
    --exclude-from="$HOMELAB_ETC/excludes.txt" \
    "$PRIMARY/" "$NAS_MOUNT/$NAS_HOMELAB_SUBDIR/"
  local rc=$?
  # 24 = file biến mất trong lúc chép (bình thường với dữ liệu đang chạy)
  if ((rc != 0 && rc != 24)); then
    die "rsync dữ liệu thất bại (mã $rc)."
  fi

  rsync -a --info=stats1 "$DUMP_DIR/" "$NAS_MOUNT/$NAS_META_SUBDIR/dumps/" || die "rsync dump thất bại."
  date '+%F %T' >"$HOMELAB_STATE/seed.last_ok"
  log "Seed hoàn tất."
}

hc_wrap "${HC_SEED:-}" "Seed lên NAS" main
