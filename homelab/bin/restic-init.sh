#!/usr/bin/env bash
# GIAI ĐOẠN 5 — Tạo mật khẩu restic (nếu chưa có) và khởi tạo kho.
# Lệnh: restic-init.sh local | mac
# ⚠️ MẤT FILE MẬT KHẨU = MẤT TOÀN BỘ BACKUP. Người phải lưu nó vào trình quản lý mật khẩu.

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars RESTIC_PASSWORD_FILE

target=${1:-}
case $target in
  local) require_vars RESTIC_REPO_LOCAL BACKUP_MOUNT; repo=$RESTIC_REPO_LOCAL
         mountpoint -q "$BACKUP_MOUNT" || die "$BACKUP_MOUNT chưa mount." ;;
  mac) require_vars RESTIC_REPO_MAC MAC_M2_USER; repo=$RESTIC_REPO_MAC ;;
  *) die "Dùng: $0 local|mac" ;;
esac

if [[ ! -s $RESTIC_PASSWORD_FILE ]]; then
  umask 077
  openssl rand -base64 33 >"$RESTIC_PASSWORD_FILE"
  log "Đã tạo $RESTIC_PASSWORD_FILE. ⛔ NGƯỜI PHẢI SAO LƯU FILE NÀY trước khi tiếp tục (sudo cat $RESTIC_PASSWORD_FILE)."
fi

if restic -r "$repo" cat config >/dev/null 2>&1; then
  log "Kho $repo đã tồn tại, bỏ qua."
else
  restic -r "$repo" init || die "Khởi tạo kho thất bại."
  log "Đã khởi tạo kho $repo"
fi
