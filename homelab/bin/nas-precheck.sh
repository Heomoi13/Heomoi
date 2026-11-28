#!/usr/bin/env bash
# GIAI ĐOẠN 3 & 6 — Kiểm tra trước/sau khi thay ổ NAS. CHỈ ĐỌC.
# Lệnh: nas-precheck.sh before   — đủ điều kiện để rút ổ chưa?
#       nas-precheck.sh rebuild  — xem tiến độ rebuild RAID
#       nas-precheck.sh after    — RAID đã về [UU] và SMART ổ mới ổn chưa?

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars NAS_IP NAS_SSH_USER PRIMARY

CMD=${1:-before}
FAIL=0
ok() { log "  ✅ $*"; }
bad() { log "  ❌ $*"; FAIL=1; }
warn() { log "  ⚠️  $*"; }

mdstat=$(nas_ssh 'cat /proc/mdstat') || die "Không SSH được vào NAS."

smart_report() {
  nas_ssh 'for d in $(lsblk -dno NAME,TYPE | awk "\$2==\"disk\" && \$1 ~ /^sd/ {print \$1}"); do
      echo "### /dev/$d"
      sudo -n smartctl -i -H -A /dev/$d 2>&1 | grep -E "Device Model|Serial Number|overall-health|^ *(5|9|197|198|199) "
    done' || warn "Không đọc được SMART (thiếu sudo không mật khẩu) — xem trong UGOS > Ổ lưu trữ."
}

case $CMD in
  before)
    log "Kiểm tra trước khi thay ổ:"
    # 1. RAID phải đang khoẻ (không thay ổ khi đã degraded, trừ khi chính ổ đó hỏng)
    if grep -qE '\[U+\]' <<<"$mdstat" && ! grep -qE '\[U*_+U*\]' <<<"$mdstat"; then
      ok "RAID khoẻ: $(grep -oE '\[[U_]+\]' <<<"$mdstat" | tr '\n' ' ')"
    else
      bad "RAID không ở trạng thái [UU] — dừng lại, báo người."
    fi
    if grep -qE 'resync|recovery|reshape|check' <<<"$mdstat"; then
      bad "RAID đang resync/check — chờ xong."
    fi
    # 2. Dữ liệu trên NAS phải có bản sao mới ở nơi khác
    if primary_on_nas; then
      f=$HOMELAB_STATE/backup-local.last_ok
      if [[ -f $f ]] && (($(date +%s) - $(stat -c %Y "$f") < 2 * 86400)); then
        ok "Backup restic local thành công lúc $(cat "$f")"
      else
        bad "Chưa có backup local thành công trong 48 giờ."
      fi
    else
      ok "Dữ liệu gốc vẫn ở HDD server — NAS chỉ giữ bản mồi, rủi ro thấp."
    fi
    # 3. UPS phải đang hoạt động
    if command -v upsc >/dev/null && upsc ups@localhost ups.status 2>/dev/null | grep -q OL; then
      ok "UPS đang chạy bằng điện lưới (OL)."
    else
      bad "UPS chưa hoạt động — hoàn thành giai đoạn 2 trước."
    fi
    smart_report
    ;;
  rebuild)
    grep -E 'md|recovery|resync|finish' <<<"$mdstat"
    ;;
  after)
    if grep -qE '\[U*_+U*\]' <<<"$mdstat" || grep -qE 'recovery|resync' <<<"$mdstat"; then
      bad "RAID chưa hoàn tất: $(grep -oE '\[[U_]+\]|recovery.*' <<<"$mdstat" | tr '\n' ' ')"
    else
      ok "RAID đã về trạng thái khoẻ."
    fi
    smart_report
    log "Nhắc người: chạy scrub Btrfs trong UGOS sau khi rebuild xong."
    ;;
  *) die "Dùng: $0 before|rebuild|after" ;;
esac

((FAIL == 0)) && log "KẾT QUẢ: ĐẠT" || { log "KẾT QUẢ: KHÔNG ĐẠT — không tiếp tục."; exit 1; }
