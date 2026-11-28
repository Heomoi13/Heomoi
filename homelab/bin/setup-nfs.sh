#!/usr/bin/env bash
# GIAI ĐOẠN 1 — Kiểm tra NFS từ NAS và tạo automount /mnt/nas-data.
# Điều kiện: người đã bật NFS trên UGOS cho share "data", chỉ cho phép 192.168.0.88,
# squash = "không ánh xạ" (no_root_squash).
# Lệnh: setup-nfs.sh test   — chỉ mount thử vào thư mục tạm rồi gỡ ra
#       setup-nfs.sh apply  — thêm dòng automount vào /etc/fstab, tạo thư mục và sentinel

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars NAS_IP NAS_NFS_EXPORT NAS_HOMELAB_SUBDIR NAS_META_SUBDIR NAS_MOUNT NFS_OPTS

CMD=${1:-test}
SRC="$NAS_IP:$NAS_NFS_EXPORT"

command -v mount.nfs >/dev/null || die "Thiếu nfs-common (apt install nfs-common)."

do_test() {
  local t
  t=$(mktemp -d /mnt/nfs-test.XXXX)
  log "Mount thử $SRC vào $t với $NFS_OPTS"
  mount -t nfs -o "$NFS_OPTS" "$SRC" "$t" || { rmdir "$t"; die "Mount thất bại. Kiểm tra quyền NFS trên UGOS và NAS_NFS_EXPORT/NFS_OPTS."; }
  local f="$t/.homelab-nfs-test-$$" ok=1
  if ! echo test >"$f"; then
    log "Không ghi được file → quyền đọc/ghi NFS chưa đúng"; ok=0
  else
    chown 12345:12345 "$f" 2>/dev/null
    if [[ $(stat -c '%u:%g' "$f") == "12345:12345" ]]; then
      log "OK: root giữ được quyền sở hữu (no_root_squash đang bật)"
    else
      log "Root KHÔNG đổi được chủ sở hữu → cần squash = 'không ánh xạ' trên UGOS"; ok=0
    fi
    log "Đo tốc độ ghi 1 GiB..."
    dd if=/dev/zero of="$f.big" bs=1M count=1024 conv=fdatasync 2>&1 | tail -1 | tee -a "$HOMELAB_LOG_DIR/$SCRIPT_NAME.log"
    sync; echo 3 >/proc/sys/vm/drop_caches
    log "Đo tốc độ đọc 1 GiB..."
    dd if="$f.big" of=/dev/null bs=1M 2>&1 | tail -1 | tee -a "$HOMELAB_LOG_DIR/$SCRIPT_NAME.log"
    rm -f "$f" "$f.big"
  fi
  umount "$t" && rmdir "$t"
  ((ok)) || die "Kiểm tra NFS chưa đạt."
  log "Kiểm tra NFS đạt."
}

do_apply() {
  do_test
  local marker="# homelab:nas-data (automount, chỉ dùng cho script)"
  if grep -qF "$marker" /etc/fstab; then
    log "fstab đã có dòng automount, bỏ qua."
  else
    cp -a /etc/fstab "/etc/fstab.homelab-$(date +%Y%m%d-%H%M%S)"
    {
      echo "$marker"
      echo "$SRC $NAS_MOUNT nfs $NFS_OPTS,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=60 0 0"
    } >>/etc/fstab
    log "Đã thêm automount vào /etc/fstab (bản sao lưu fstab nằm cạnh)."
  fi
  mkdir -p "$NAS_MOUNT"
  systemctl daemon-reload
  systemctl restart "$(systemd-escape -p --suffix=automount "$NAS_MOUNT")"
  ls "$NAS_MOUNT" >/dev/null || die "Không truy cập được $NAS_MOUNT"
  is_nfs_mount "$NAS_MOUNT" || die "$NAS_MOUNT không phải mount NFS"
  mkdir -p "$NAS_MOUNT/$NAS_HOMELAB_SUBDIR" "$NAS_MOUNT/$NAS_META_SUBDIR/dumps"
  if [[ ! -f $NAS_MOUNT/$NAS_HOMELAB_SUBDIR/$SENTINEL ]]; then
    printf 'Thư mục dữ liệu gốc homelab trên NAS. Tạo lúc %s. KHÔNG XOÁ file này.\n' "$(date '+%F %T')" \
      >"$NAS_MOUNT/$NAS_HOMELAB_SUBDIR/$SENTINEL"
  fi
  log "Xong: $NAS_MOUNT/$NAS_HOMELAB_SUBDIR đã sẵn sàng, có sentinel."
}

case $CMD in
  test) do_test ;;
  apply) do_apply ;;
  *) die "Dùng: $0 test|apply" ;;
esac
