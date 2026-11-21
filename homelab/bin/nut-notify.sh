#!/usr/bin/env bash
# Được upsmon gọi khi có sự kiện UPS (mất điện, có điện lại, pin cần thay...).
# NOTIFYCMD chạy với user nut nên không đọc được secrets.env (600, root).
# Vì vậy dùng file riêng /etc/homelab/telegram.env (640, root:nut) chỉ chứa 2 biến Telegram.
SECRETS=/etc/homelab/telegram.env
msg="[homelab UPS] ${NOTIFYTYPE:-?}: $*"
logger -t homelab-ups "$msg"
if [[ -r $SECRETS ]]; then
  # shellcheck disable=SC1090
  . "$SECRETS"
  curl -fsS -m 15 -o /dev/null --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$msg" "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" || true
fi
