#!/usr/bin/env bash
# GIAI ĐOẠN 5 — Backup dữ liệu gốc (trên NAS, qua /srv/nas) bằng restic.
# Lệnh: restic-backup.sh local   — vào ổ HDD 3TB trên server (hằng đêm 02:30)
#       restic-backup.sh mac     — vào Mac M2 qua SFTP (hằng đêm 04:00)
# Có lịch sử phiên bản: file bị hỏng/bị mã hoá không ghi đè lên bản tốt.

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars PRIMARY BACKUP_PATHS RESTIC_PASSWORD_FILE RESTIC_KEEP

target=${1:-}
case $target in
  local) require_vars RESTIC_REPO_LOCAL BACKUP_MOUNT; repo=$RESTIC_REPO_LOCAL; hc=${HC_BACKUP_LOCAL:-} ;;
  mac) require_vars RESTIC_REPO_MAC MAC_M2_HOST; repo=$RESTIC_REPO_MAC; hc=${HC_BACKUP_MAC:-} ;;
  *) die "Dùng: $0 local|mac" ;;
esac

main() {
  take_lock backup
  # Nguồn phải là NAS thật, không phải thư mục rỗng
  primary_on_nas || die "$PRIMARY không phải NFS có sentinel — không backup để tránh chụp thư mục rỗng."
  if [[ $target == local ]]; then
    mountpoint -q "$BACKUP_MOUNT" || die "$BACKUP_MOUNT chưa mount (ổ backup hỏng/rút?)."
  else
    ping -c1 -W3 "$MAC_M2_HOST" >/dev/null || die "Mac M2 không phản hồi."
  fi

  "$(dirname "$(readlink -f "$0")")/immich-db-dump.sh" || die "Dump DB Immich thất bại."

  local ex=(--exclude-file="$HOMELAB_ETC/restic-excludes.txt" --exclude-caches)
  local p
  for p in $BACKUP_EXCLUDE_PATHS; do ex+=(--exclude="$p"); done

  log "restic backup → $repo"
  # shellcheck disable=SC2086
  restic -r "$repo" backup $BACKUP_PATHS "${ex[@]}" \
    --one-file-system --host homeserver --tag nightly --no-scan
  local rc=$?
  case $rc in
    0) ;;
    3) log "Cảnh báo: một số file không đọc được (mã 3) — snapshot vẫn được tạo." ;;
    *) die "restic backup thất bại (mã $rc)." ;;
  esac

  # shellcheck disable=SC2086
  restic -r "$repo" forget --host homeserver $RESTIC_KEEP || die "restic forget thất bại."
  date '+%F %T' >"$HOMELAB_STATE/backup-$target.last_ok"
  log "Backup $target xong. Snapshot gần nhất:"
  restic -r "$repo" snapshots --latest 1 --compact
}

hc_wrap "$hc" "Backup restic ($target)" main
