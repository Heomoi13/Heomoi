#!/usr/bin/env bash
# GIAI ĐOẠN 5 — Giám sát bổ sung, gửi Telegram khi có vấn đề (chống lặp 24 giờ).
# Lệnh: monitor.sh storage     — hằng giờ: mount NAS, dung lượng NAS / ổ backup / Mac
#       monitor.sh nas-health  — hằng ngày: RAID NAS và SMART 2 ổ NAS

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars PRIMARY NAS_IP NAS_SSH_USER DISK_WARN_PCT

check_pct() { # check_pct <key> <tên> <phần trăm>
  local key=$1 name=$2 pct=$3
  if [[ -z $pct ]]; then
    alert "$key-read" "Không đọc được dung lượng $name"
  elif ((pct >= DISK_WARN_PCT)); then
    alert "$key" "$name đã dùng ${pct}% (ngưỡng ${DISK_WARN_PCT}%)"
  else
    clear_alert "$key" "$name trở lại ${pct}%"
    clear_alert "$key-read" "Đã đọc lại được dung lượng $name"
  fi
}

storage() {
  # Mount dữ liệu gốc (chỉ sau cutover)
  if [[ -f $HOMELAB_STATE/cutover.state ]]; then
    if primary_on_nas; then
      clear_alert primary-mount "$PRIMARY đã mount lại từ NAS"
      check_pct nas-space "Volume NAS" "$(df --output=pcent "$PRIMARY" | tail -1 | tr -dc 0-9)"
    else
      alert primary-mount "$PRIMARY KHÔNG mount từ NAS — Immich/Syncthing không truy cập được dữ liệu gốc!"
    fi
  fi
  # Ổ backup local (chỉ sau giai đoạn 5a)
  if grep -q 'homelab:backup-disk' /etc/fstab; then
    if mountpoint -q "$BACKUP_MOUNT"; then
      clear_alert backup-mount "$BACKUP_MOUNT đã mount lại"
      check_pct backup-space "Ổ backup HDD 3TB" "$(df --output=pcent "$BACKUP_MOUNT" | tail -1 | tr -dc 0-9)"
    else
      alert backup-mount "$BACKUP_MOUNT không mount — ổ backup 3TB có thể đã hỏng"
    fi
  fi
  # Ổ backup trên Mac M2 chỉ mount lúc backup → kiểm tra dung lượng nằm trong restic-backup.sh mac
}

nas_health() {
  local mdstat
  if ! mdstat=$(nas_ssh 'cat /proc/mdstat' 2>/dev/null); then
    alert nas-ssh "Không SSH được vào NAS để kiểm tra RAID"
    return 1
  fi
  clear_alert nas-ssh "SSH vào NAS bình thường trở lại"
  if grep -qE '\[U*_+U*\]' <<<"$mdstat"; then
    alert nas-raid "RAID NAS bị DEGRADED: $(grep -oE '\[[U_]+\]' <<<"$mdstat" | tr '\n' ' ') — thay ổ sớm!"
  else
    clear_alert nas-raid "RAID NAS đã khoẻ lại"
  fi

  # SMART: cảnh báo khi các chỉ số 5/197/198/199 > 0 và tăng so với lần trước
  local out
  out=$(nas_ssh 'for d in $(lsblk -dno NAME,TYPE | awk "\$2==\"disk\" && \$1 ~ /^sd/ {print \$1}"); do
      s=$(sudo -n smartctl -i /dev/$d 2>/dev/null | awk -F: "/Serial Number/{gsub(/ /,\"\",\$2); print \$2}")
      [ -n "$s" ] || { echo "NOACCESS"; continue; }
      sudo -n smartctl -A /dev/$d | awk -v s="$s" "\$1 ~ /^(5|197|198|199)\$/ {print s, \$1, \$10}"
    done' 2>/dev/null)
  if grep -q NOACCESS <<<"$out" || [[ -z $out ]]; then
    alert nas-smart-access "Không đọc được SMART của NAS (cần sudo không mật khẩu cho smartctl, hoặc bật cảnh báo ổ đĩa trong UGOS)"
    return 0
  fi
  clear_alert nas-smart-access "Đọc được SMART của NAS"
  local serial id raw prev f
  while read -r serial id raw; do
    f=$HOMELAB_STATE/smart-$serial-$id
    prev=$(cat "$f" 2>/dev/null || echo 0)
    if ((raw > prev)); then
      alert "smart-$serial-$id" "Ổ NAS $serial: SMART ID $id tăng từ $prev lên $raw"
    fi
    echo "$raw" >"$f"
  done <<<"$out"
}

case ${1:-} in
  storage) hc_wrap "${HC_MONITOR:-}" "Giám sát dung lượng" storage ;;
  nas-health) nas_health ;;
  *) die "Dùng: $0 storage|nas-health" ;;
esac
