#!/usr/bin/env bash
# GIAI ĐOẠN 7 — Diễn tập khôi phục (mỗi quý). Không đụng vào dữ liệu thật.
#   1. Lấy ngẫu nhiên 20 file từ snapshot mới nhất, so SHA-256 với file đang có.
#   2. Lấy bản dump Immich mới nhất trong snapshot, kiểm tra giải nén và nội dung.
# Lệnh: restore-drill.sh [local|mac]

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars RESTIC_PASSWORD_FILE PRIMARY DUMP_DIR
command -v jq >/dev/null || die "Thiếu jq (apt install jq)."

work=$(mktemp -d /var/tmp/restore-drill.XXXX)
trap 'rm -rf "$work"' EXIT
target=${1:-local}
case $target in
  local) repo=$RESTIC_REPO_LOCAL ;;
  mac) repo=$RESTIC_REPO_MAC; mac_mount_disk; trap 'mac_unmount_disk; rm -rf "$work"' EXIT ;;
  *) die "Dùng: $0 local|mac" ;;
esac

snap_time=$(restic -r "$repo" snapshots latest --json | jq -r '.[0].time') || die "Không đọc được snapshot."
snap_epoch=$(date -d "$snap_time" +%s)
log "Snapshot mới nhất: $snap_time"

restic -r "$repo" ls latest --json \
  | jq -r --arg p "$PRIMARY/" 'select(.type=="file" and (.path|startswith($p))) | .path' \
  | shuf -n 20 >"$work/list"

ok=0 changed=0 bad=0
while IFS= read -r f; do
  restic -r "$repo" dump latest "$f" >"$work/file" 2>/dev/null || { log "❌ Không lấy ra được: $f"; bad=$((bad + 1)); continue; }
  if [[ ! -f $f ]]; then
    changed=$((changed + 1))   # file đã bị xoá/đổi tên sau snapshot — không tính lỗi
  elif (($(stat -c %Y "$f") > snap_epoch)); then
    changed=$((changed + 1))   # file đã sửa sau snapshot
  elif [[ $(sha256sum <"$work/file" | cut -d' ' -f1) == $(sha256sum <"$f" | cut -d' ' -f1) ]]; then
    ok=$((ok + 1))
  else
    log "❌ Khác nội dung: $f"; bad=$((bad + 1))
  fi
done <"$work/list"
log "File: $ok khớp, $changed đã thay đổi sau snapshot, $bad lỗi"

dump=$(restic -r "$repo" ls latest "$DUMP_DIR" 2>/dev/null | grep -E "${IMMICH_DB_CONTAINER:-immich_postgres}-.*\\.sql\\.gz\$" | sort | tail -1)
dump_ok=0
if [[ -n $dump ]]; then
  restic -r "$repo" dump latest "$dump" >"$work/dump.sql.gz"
  if gzip -t "$work/dump.sql.gz" && { zcat "$work/dump.sql.gz" || true; } | grep -qm1 'CREATE DATABASE'; then
    dump_ok=1
    log "✅ Dump DB $(basename "$dump") giải nén được và có CREATE DATABASE"
  fi
fi
((dump_ok)) || { log "❌ Không có dump DB hợp lệ trong snapshot"; bad=$((bad + 1)); }

msg="Diễn tập khôi phục ($target): $ok/20 file khớp, $changed thay đổi, $bad lỗi, dump DB $([[ $dump_ok == 1 ]] && echo OK || echo LỖI)"
if ((bad == 0)); then tg_send "✅ $msg"; else tg_send "❌ $msg"; exit 1; fi
