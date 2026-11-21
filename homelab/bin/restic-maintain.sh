#!/usr/bin/env bash
# GIAI ĐOẠN 5 — Bảo trì kho restic hằng tuần: dọn dữ liệu cũ (prune) và kiểm tra tính toàn vẹn
# (đọc ngẫu nhiên 5% dữ liệu mỗi tuần → khoảng 5 tháng đọc hết một lượt).
# Lệnh: restic-maintain.sh            — cả hai kho
#       restic-maintain.sh local|mac

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars RESTIC_PASSWORD_FILE

targets=${1:-"local mac"}

main() {
  take_lock backup
  local t repo fail=0
  for t in $targets; do
    case $t in
      local) repo=$RESTIC_REPO_LOCAL ;;
      mac) repo=$RESTIC_REPO_MAC
           ( mac_mount_disk ) || { fail=1; continue; }
           MAC_MOUNTED_BY_US=1; trap mac_unmount_disk EXIT ;;
      *) die "Kho không hợp lệ: $t" ;;
    esac
    if ! restic -r "$repo" cat config >/dev/null 2>&1; then
      log "Bỏ qua $t: kho chưa khởi tạo hoặc không truy cập được."; fail=1; continue
    fi
    log "[$t] prune"
    restic -r "$repo" prune || { log "[$t] prune lỗi"; fail=1; }
    log "[$t] check --read-data-subset=5%"
    restic -r "$repo" check --read-data-subset=5% || { log "[$t] CHECK LỖI — kho có thể hỏng"; fail=1; }
    restic -r "$repo" stats --mode raw-data | tail -3
  done
  return $fail
}

hc_wrap "${HC_MAINTAIN:-}" "Bảo trì restic" main
