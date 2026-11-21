#!/usr/bin/env bash
# GIAI ĐOẠN 0 — Khảo sát hiện trạng homeserver, NAS và Mac M2.
# CHỈ ĐỌC: không ghi, không sửa, không khởi động lại bất cứ thứ gì.
# Kết quả: /var/lib/homelab/reports/discovery-<thời-gian>.md
# Bí mật (token, mật khẩu, UUID Healthchecks) được che trước khi ghi ra.

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config optional

NAS_IP=${NAS_IP:-192.168.1.123}
NAS_SSH_USER=${NAS_SSH_USER:-nando}
PRIMARY=${PRIMARY:-/srv/nas}
MAC_M2_HOST=${MAC_M2_HOST:-192.168.0.77}
MAC_M2_USER=${MAC_M2_USER:-}
MAC_M2_BACKUP_DIR=${MAC_M2_BACKUP_DIR:-/Volumes/Backup}

REPORT_DIR=$HOMELAB_STATE/reports
mkdir -p "$REPORT_DIR"
REPORT=$REPORT_DIR/discovery-$(date +%Y%m%d-%H%M).md

redact() {
  sed -E \
    -e 's/[0-9]{6,}:[A-Za-z0-9_-]{30,}/<TELEGRAM_TOKEN>/g' \
    -e 's#(hc-ping\.com/)[A-Za-z0-9_-]+#\1<UUID>#g' \
    -e 's/(([A-Z_]*(PASSWORD|PASS|TOKEN|SECRET|APIKEY|API_KEY))[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1<ẨN>/Ig'
}

section() { printf '\n## %s\n\n' "$*"; }
run() { # run <tiêu đề> <lệnh...> — in lệnh và kết quả trong khối code
  printf '**%s**\n\n```\n$ %s\n' "$1" "${*:2}"
  timeout 1800 "${@:2}" 2>&1 | redact
  printf '```\n\n'
}

FLAGS=()
flag() { FLAGS+=("$*"); }

{
  echo "# Báo cáo khảo sát homelab — $(date '+%F %T')"

  section "1. Hệ thống"
  run "Máy" hostnamectl
  run "RAM / CPU" bash -c 'free -h; nproc'
  run "Thời gian chạy" uptime

  section "2. Ổ đĩa và mount"
  run "lsblk" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL
  run "Đường dẫn ổ theo ID" bash -c "ls -l /dev/disk/by-id/ | grep -E 'ata-|nvme-' | awk '{print \$9, \$10, \$11}'"
  run "Dung lượng" df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs
  run "/etc/fstab" cat /etc/fstab
  run "Mount của $PRIMARY" findmnt "$PRIMARY"
  run "Mount SMB /mnt/nas-ugreen" findmnt /mnt/nas-ugreen

  section "3. Dữ liệu trong $PRIMARY"
  run "Tổng" du -xsh "$PRIMARY"
  run "Chi tiết 2 cấp (40 thư mục lớn nhất)" bash -c "du -xh --max-depth=2 '$PRIMARY' 2>/dev/null | sort -h | tail -40"
  run "File database/SQLite nằm trong $PRIMARY (KHÔNG được để trên NFS)" \
    bash -c "find '$PRIMARY' -xdev \\( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o -name 'PG_VERSION' -o -name '*.db-wal' \\) -printf '%p\t%s bytes\n' 2>/dev/null | head -100"

  section "4. Docker: container và thư mục được mount"
  run "Container" docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  printf '**Mount của từng container** (dấu ⚠️ = dùng %s)\n\n```\n' "$PRIMARY"
  for id in $(docker ps -aq 2>/dev/null); do
    docker inspect -f '{{.Name}} | project={{index .Config.Labels "com.docker.compose.project"}} | dir={{index .Config.Labels "com.docker.compose.project.working_dir"}}{{range .Mounts}}
    {{.Type}} {{.Source}} -> {{.Destination}}{{end}}' "$id" 2>/dev/null \
      | sed -E "s#^( +[a-z]+ ${PRIMARY}([/ ].*)?)\$#\1   ⚠️#"
  done
  printf '```\n\n'

  section "5. Immich"
  IMMICH_DIR=$(docker ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null | awk '/immich-server/{print $1; exit}' \
    | xargs -r docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
  echo "- Thư mục compose: \`${IMMICH_DIR:-không tìm thấy}\`"
  if [[ -n $IMMICH_DIR && -r $IMMICH_DIR/.env ]]; then
    run "Biến đường dẫn trong .env (không in mật khẩu)" \
      grep -E '^(UPLOAD_LOCATION|DB_DATA_LOCATION|IMMICH_VERSION|DB_USERNAME|DB_DATABASE_NAME)=' "$IMMICH_DIR/.env"
    run "File compose" bash -c "ls -la '$IMMICH_DIR'"
    DBLOC=$(grep -E '^DB_DATA_LOCATION=' "$IMMICH_DIR/.env" | cut -d= -f2-)
    [[ $DBLOC == ./* ]] && DBLOC="$IMMICH_DIR/${DBLOC#./}"
    if [[ -n $DBLOC && $(readlink -f "$DBLOC") == "$PRIMARY"* ]]; then
      flag "⛔ Postgres của Immich đang ở $DBLOC (trong $PRIMARY). PHẢI chuyển sang SSD trước cutover (giai đoạn 4, bước 4.1)."
    fi
  else
    flag "Không đọc được .env của Immich — người cần chỉ ra thư mục compose."
  fi
  run "Container Postgres" bash -c "docker ps -a --format '{{.Names}} {{.Image}}' | grep -Ei 'postgres|pgvecto|vectorchord'"

  section "6. Lịch chạy hiện có (cron, systemd timer)"
  run "crontab root" crontab -l
  run "crontab các user" bash -c 'for f in /var/spool/cron/crontabs/*; do [ -f "$f" ] && { echo "### $f"; cat "$f"; }; done'
  run "/etc/cron.d" bash -c 'for f in /etc/cron.d/*; do echo "### $f"; cat "$f"; done'
  run "systemd timers" systemctl list-timers --all --no-pager
  printf '**Nội dung các script được cron gọi**\n\n'
  SCRIPTS=$( { crontab -l 2>/dev/null; cat /var/spool/cron/crontabs/* /etc/cron.d/* 2>/dev/null; } \
    | grep -v '^\s*#' | grep -oE '/[^ ;|&>]+\.(sh|py)' | sort -u)
  for s in $SCRIPTS; do
    [[ -r $s ]] && run "$s" cat "$s"
  done

  section "7. Mạng"
  run "Địa chỉ IP" ip -br addr
  IFACE=$(ip route show default | awk '{print $5; exit}')
  run "Tốc độ cổng $IFACE" bash -c "ethtool '$IFACE' 2>/dev/null | grep -E 'Speed|Duplex'"
  run "Samba trên homeserver" bash -c 'systemctl is-active smbd; testparm -s 2>/dev/null | grep -E "^\[|path"'

  section "8. Công cụ đã cài"
  printf '```\n'
  for t in restic rsync wakeonlan showmount mount.nfs smartctl upsc upsmon jq curl ethtool chattr; do
    if p=$(command -v "$t"); then
      printf '%-12s %s  %s\n' "$t" "$p" "$("$t" --version 2>&1 | head -1)"
    else
      printf '%-12s CHƯA CÀI\n' "$t"
    fi
  done
  printf '```\n\n'
  if command -v restic >/dev/null; then
    rv=$(restic version | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ $(printf '%s\n0.16\n' "$rv" | sort -V | head -1) != 0.16 ]]; then
      flag "restic $rv quá cũ — cần ≥ 0.16 (tải bản phát hành chính thức từ GitHub)."
    fi
  fi

  section "9. NAS ($NAS_IP)"
  run "ping" ping -c2 -W2 "$NAS_IP"
  if timeout 3 bash -c "</dev/tcp/$NAS_IP/2049" 2>/dev/null; then
    echo "- Cổng NFS 2049: **mở**"
  else
    echo "- Cổng NFS 2049: **đóng** (NFS chưa bật hoặc NAS đang ngủ)"
    flag "NFS trên NAS chưa bật — người bật ở giai đoạn 1, bước 1.1."
  fi
  command -v showmount >/dev/null && run "Export NFS" showmount -e "$NAS_IP"
  run "SSH (root của server → $NAS_SSH_USER@NAS)" \
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$NAS_SSH_USER@$NAS_IP" \
    'uname -a; id; if sudo -n true 2>/dev/null; then echo SUDO_NOPASSWD=yes; else echo SUDO_NOPASSWD=no; fi; echo; cat /proc/mdstat; echo; df -h; echo; lsblk -dno NAME,SIZE,MODEL,SERIAL'
  run "SMART ổ NAS (cần sudo không mật khẩu)" \
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$NAS_SSH_USER@$NAS_IP" \
    'for d in $(lsblk -dno NAME,TYPE | awk "\$2==\"disk\" && \$1 ~ /^sd/ {print \$1}"); do echo "### /dev/$d"; sudo -n smartctl -i -A /dev/$d | grep -E "Device Model|Serial|^ *(5|9|197|198|199) "; done'

  section "10. Mac mini M2 ($MAC_M2_HOST)"
  run "ping" ping -c2 -W2 "$MAC_M2_HOST"
  if [[ -n $MAC_M2_USER && $MAC_M2_USER != CHANGE_ME ]]; then
    run "Dung lượng ổ backup" ssh -o BatchMode=yes -o ConnectTimeout=10 "$MAC_M2_USER@$MAC_M2_HOST" \
      "df -h '$MAC_M2_BACKUP_DIR'; ls -la '$MAC_M2_BACKUP_DIR'"
  else
    echo "- Chưa biết user SSH của Mac M2: lấy từ lệnh rsync trong cron ở mục 6, điền MAC_M2_USER rồi chạy lại."
  fi

  section "11. Đánh giá dung lượng"
  used=$(df -B1 --output=used "$PRIMARY" 2>/dev/null | tail -1)
  nvme_avail=$(df -B1 --output=avail / | tail -1)
  printf -- '- Dữ liệu trong %s: **%s**\n' "$PRIMARY" "$(numfmt --to=iec "${used:-0}")"
  printf -- '- Còn trống trên SSD (/): **%s**\n' "$(numfmt --to=iec "${nvme_avail:-0}")"
  echo "- So sánh thủ công với: dung lượng trống trên NAS (mục 9) và ổ Mac (mục 10)."
  if [[ -n $used ]] && ((used > 2200000000000)); then
    flag "Dữ liệu > 2,2 TB: ổ backup 3TB sẽ chật khi giữ nhiều phiên bản; Mac 1,8TB không chứa nổi một bản đầy đủ."
  elif [[ -n $used ]] && ((used > 1600000000000)); then
    flag "Dữ liệu > 1,6 TB: Mac M2 (1,8TB) có thể không đủ chỗ cho kho restic — cân nhắc loại trừ bớt."
  fi

  section "12. Việc cần người quyết định"
  if ((${#FLAGS[@]} == 0)); then
    echo "- Không phát hiện vấn đề chặn."
  else
    for f in "${FLAGS[@]}"; do echo "- $f"; done
  fi
  cat <<'EOF'
- Xác nhận danh sách container sẽ bị dừng khi cutover (các dòng ⚠️ ở mục 4).
- Quyết định cho từng file SQLite ở mục 3 (chuyển sang SSD hay chấp nhận để trên NFS).
- Đề xuất bổ sung BACKUP_PATHS: thư mục compose/config của các stack (mục 4, cột dir=).
- Xác nhận các giá trị CHANGE_ME trong /etc/homelab/homelab.env.
EOF
} >"$REPORT"

log "Đã ghi báo cáo: $REPORT"
cat "$REPORT"
