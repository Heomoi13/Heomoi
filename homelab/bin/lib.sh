#!/usr/bin/env bash
# Thư viện dùng chung cho các script homelab. Được `source`, không chạy trực tiếp.
# Không bao giờ in giá trị bí mật (token, mật khẩu) ra log.

set -o pipefail

HOMELAB_ETC=${HOMELAB_ETC:-/etc/homelab}
HOMELAB_STATE=${HOMELAB_STATE:-/var/lib/homelab}
HOMELAB_LOG_DIR=${HOMELAB_LOG_DIR:-/var/log/homelab}
SCRIPT_NAME=$(basename "$0" .sh)
SENTINEL=.nas-homelab-sentinel

log() {
  local line
  line="$(date '+%F %T') [$SCRIPT_NAME] $*"
  printf '%s\n' "$line" >&2
  if [[ -d $HOMELAB_LOG_DIR && -w $HOMELAB_LOG_DIR ]]; then
    printf '%s\n' "$line" >>"$HOMELAB_LOG_DIR/$SCRIPT_NAME.log"
  fi
}

die() { log "LỖI: $*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Cần chạy bằng root (sudo)."; }

# Nạp cấu hình. Nếu $1 = optional thì không báo lỗi khi thiếu file (dùng cho khảo sát).
load_config() {
  local mode=${1:-required}
  if [[ -r $HOMELAB_ETC/homelab.env ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$HOMELAB_ETC/homelab.env"
    # shellcheck disable=SC1091
    [[ -r $HOMELAB_ETC/secrets.env ]] && . "$HOMELAB_ETC/secrets.env"
    set +a
  elif [[ $mode != optional ]]; then
    echo "Thiếu $HOMELAB_ETC/homelab.env — chạy install.sh rồi điền cấu hình." >&2
    exit 2
  fi
  mkdir -p "$HOMELAB_STATE" "$HOMELAB_LOG_DIR" 2>/dev/null || true
  export RESTIC_PASSWORD_FILE
}

# Bắt buộc các biến đã được điền (không rỗng, không còn CHANGE_ME).
require_vars() {
  local v
  for v in "$@"; do
    [[ -n ${!v:-} && ${!v} != *CHANGE_ME* ]] || die "Biến $v chưa được cấu hình trong $HOMELAB_ETC/homelab.env"
  done
}

tg_send() {
  if [[ -z ${TELEGRAM_BOT_TOKEN:-} || -z ${TELEGRAM_CHAT_ID:-} ]]; then
    log "Telegram chưa cấu hình, bỏ qua tin nhắn: $*"
    return 0
  fi
  curl -fsS -m 15 --retry 2 -o /dev/null \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=[homelab $(hostname -s)] $*" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    || log "Gửi Telegram thất bại"
}

# hc_ping <url> <start|fail|mã-thoát> [file-log]
hc_ping() {
  local url=${1:-} what=$2 body=${3:-}
  [[ -n $url ]] || return 0
  if [[ -n $body && -r $body ]]; then
    tail -c 10000 "$body" | curl -fsS -m 15 --retry 3 -o /dev/null --data-binary @- "$url/$what" \
      || log "Ping Healthchecks thất bại ($what)"
  else
    curl -fsS -m 15 --retry 3 -o /dev/null "$url/$what" || log "Ping Healthchecks thất bại ($what)"
  fi
}

# hc_wrap <hc-url> <nhãn> <lệnh...> — báo start/kết quả lên Healthchecks, Telegram khi lỗi.
hc_wrap() {
  local url=$1 label=$2 out rc
  shift 2
  out=$(mktemp)
  hc_ping "$url" start
  "$@" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  hc_ping "$url" "$rc" "$out"
  if ((rc != 0)); then
    tg_send "❌ $label thất bại (mã $rc). Xem log: $HOMELAB_LOG_DIR/"
  fi
  rm -f "$out"
  return "$rc"
}

# Khoá để không chạy chồng hai tiến trình cùng loại.
take_lock() {
  local name=$1
  exec {LOCK_FD}>"/run/lock/homelab-$name.lock"
  flock -n "$LOCK_FD" || die "Đang có một tiến trình '$name' khác chạy."
}

is_nfs_mount() {
  mountpoint -q "$1" 2>/dev/null && [[ $(findmnt -n -o FSTYPE "$1") == nfs* ]]
}

# Dữ liệu gốc đã nằm trên NAS (sau cutover)?
primary_on_nas() {
  is_nfs_mount "$PRIMARY" && [[ -f $PRIMARY/$SENTINEL ]]
}

nas_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${NAS_SSH_USER}@${NAS_IP}" "$@"
}

mac_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${MAC_M2_USER}@${MAC_M2_HOST}" "$@"
}

nas_port_open() {
  timeout 3 bash -c "</dev/tcp/${NAS_IP}/2049" 2>/dev/null
}

# Đánh thức NAS bằng Wake-on-LAN nếu cần (chỉ dùng trước cutover, khi NAS còn ngủ).
nas_wake() {
  if ping -c1 -W2 "$NAS_IP" >/dev/null 2>&1 && nas_port_open; then
    return 0
  fi
  command -v wakeonlan >/dev/null || die "Thiếu wakeonlan (apt install wakeonlan)."
  log "NAS chưa phản hồi, gửi Wake-on-LAN tới $NAS_MAC"
  wakeonlan "$NAS_MAC" >/dev/null
  local i
  for i in $(seq 1 60); do
    sleep 5
    if ping -c1 -W2 "$NAS_IP" >/dev/null 2>&1 && nas_port_open; then
      log "NAS đã thức sau $((i * 5)) giây"
      sleep 20
      return 0
    fi
  done
  die "NAS không thức dậy sau 5 phút."
}

# Kích hoạt automount và kiểm tra thư mục đích trên NAS có sentinel.
nas_dest_ready() {
  local dest="$NAS_MOUNT/$NAS_HOMELAB_SUBDIR"
  ls "$NAS_MOUNT" >/dev/null 2>&1 || return 1
  is_nfs_mount "$NAS_MOUNT" || return 1
  [[ -f $dest/$SENTINEL ]]
}

# Cảnh báo có chống lặp: chỉ gửi lại sau 24 giờ.
alert() {
  local key=$1 msg=$2 f="$HOMELAB_STATE/alert-$1"
  if [[ ! -f $f ]] || (($(date +%s) - $(stat -c %Y "$f") > 86400)); then
    tg_send "⚠️ $msg"
    touch "$f"
  fi
  log "CẢNH BÁO [$key]: $msg"
}

clear_alert() {
  local key=$1 msg=$2 f="$HOMELAB_STATE/alert-$1"
  if [[ -f $f ]]; then
    rm -f "$f"
    tg_send "✅ $msg"
  fi
}
