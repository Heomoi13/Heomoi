#!/usr/bin/env bash
# GIAI ĐOẠN 5a — Format ổ HDD 3TB cũ thành ổ backup /srv/backup.
# ⚠️ XOÁ TOÀN BỘ dữ liệu trên ổ HDD cũ. Chỉ chạy khi:
#   - cutover đã xong ít nhất 14 ngày và mọi thứ chạy ổn,
#   - người đã xác nhận bằng cách truyền đúng đường dẫn partition.
# Lệnh: CONFIRM_DEVICE=/dev/disk/by-id/...-part1 prepare-backup-disk.sh

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars OLD_HDD_PART OLD_HDD_MOUNT BACKUP_MOUNT PRIMARY

[[ ${CONFIRM_DEVICE:-} == "$OLD_HDD_PART" ]] \
  || die "CONFIRM_DEVICE phải đúng bằng OLD_HDD_PART ($OLD_HDD_PART)."
[[ -b $OLD_HDD_PART ]] || die "$OLD_HDD_PART không tồn tại."
[[ $OLD_HDD_PART == *ST3000DM003* ]] || die "Partition không phải ổ Seagate ST3000DM003 — dừng để tránh xoá nhầm."
primary_on_nas || die "Dữ liệu gốc chưa ở trên NAS — không được format HDD."

state=$HOMELAB_STATE/cutover.state
[[ -f $state ]] || die "Không có trạng thái cutover."
age_days=$((($(date +%s) - $(date -d "$(cat "$state")" +%s)) / 86400))
if ((age_days < 14)) && [[ ${FORCE:-} != yes ]]; then
  die "Cutover mới được $age_days ngày (cần ≥ 14). Đặt FORCE=yes nếu người đồng ý làm sớm."
fi

dev=$(readlink -f "$OLD_HDD_PART")
if findmnt -S "$dev" >/dev/null; then
  log "Gỡ $dev khỏi $(findmnt -n -o TARGET -S "$dev")"
  umount "$dev" || die "Không gỡ được $dev"
fi

log "Format $dev (ext4, nhãn homelab-backup)"
mkfs.ext4 -F -L homelab-backup -m 0 "$dev" || die "mkfs thất bại"
uuid=$(blkid -s UUID -o value "$dev")

bak=/etc/fstab.homelab-backupdisk-$(date +%Y%m%d-%H%M%S)
cp -a /etc/fstab "$bak"
# Bỏ dòng OLD_HDD_MOUNT, thêm dòng BACKUP_MOUNT
awk -v o="$OLD_HDD_MOUNT" '!( !/^[[:space:]]*#/ && $2==o )' "$bak" >/etc/fstab.new
{
  echo "# homelab:backup-disk (Seagate 3TB, bản sao thứ 2)"
  echo "UUID=$uuid $BACKUP_MOUNT ext4 defaults,noatime,nofail 0 2"
} >>/etc/fstab.new
mv /etc/fstab.new /etc/fstab
mkdir -p "$BACKUP_MOUNT"
systemctl daemon-reload
mount "$BACKUP_MOUNT" || die "Không mount được $BACKUP_MOUNT"
rmdir "$OLD_HDD_MOUNT" 2>/dev/null
chmod 700 "$BACKUP_MOUNT"

# Ổ chỉ dùng mỗi đêm một lần: cho phép tự dừng quay sau 30 phút
disk=/dev/$(lsblk -no PKNAME "$dev")
hdparm -S 241 "$disk" >/dev/null 2>&1 && log "Đặt spin-down 30 phút cho $disk (cần thêm vào /etc/hdparm.conf để giữ sau reboot)"

log "Xong: $BACKUP_MOUNT sẵn sàng. Tiếp theo: restic-init.sh local"
