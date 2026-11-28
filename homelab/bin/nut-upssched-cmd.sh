#!/usr/bin/env bash
# CMDSCRIPT của upssched — chạy bằng user nut, KHÔNG có quyền root.
# Chỉ làm 2 việc: nhắn Telegram (bot cảnh báo) và đặt yêu cầu tắt máy cho systemd (homelab-ups-fsd.path) xử lý.
# Token đọc từ /etc/homelab/telegram.env (640 root:nut), không in ra đâu.

ENV_FILE=/etc/homelab/telegram.env
REQUEST=/run/nut/homelab-fsd-request

send() {
  logger -t homelab-ups "$*"
  [[ -r $ENV_FILE ]] || return 0
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]] || return 0
  curl -fsS -m 15 -o /dev/null \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=[homelab UPS] $*" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" || true
}

charge() { upsc ups@localhost battery.charge 2>/dev/null || echo "?"; }

case ${1:-} in
  notify_onbatt)   send "⚡ Mất điện — đang chạy pin ($(charge)%). Chưa có điện lại sau 3 phút sẽ tắt có thứ tự." ;;
  notify_online)   send "✅ Có điện lại (pin $(charge)%)." ;;
  onbatt_shutdown) send "🔻 Mất điện đã 3 phút — bắt đầu tắt có thứ tự."; : >"$REQUEST" ;;
  notify_lowbatt)  send "🪫 Pin UPS yếu ($(charge)%)." ;;
  notify_fsd)      send "⏻ FSD: NAS rồi server đang tắt." ;;
  notify_commbad|notify_nocomm) send "⚠️ Mất kết nối với UPS — kiểm tra cáp USB." ;;
  notify_commok)   send "✅ Kết nối với UPS bình thường trở lại." ;;
  notify_replbatt) send "🔋 UPS báo cần thay pin." ;;
  *) logger -t homelab-ups "upssched-cmd: lệnh không biết: ${1:-trống}" ;;
esac
