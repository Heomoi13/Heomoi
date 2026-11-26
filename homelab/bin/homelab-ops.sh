#!/usr/bin/env bash
# Cổng sudo duy nhất cho Hermes. Chỉ chạy được các lệnh cố định bên dưới, không nhận tham số tự do.
# sudoers:  namdo ALL=(root) NOPASSWD: /opt/homelab/bin/homelab-ops.sh
#
# Nguyên tắc:
#  - Lệnh chỉ đọc / kiểm tra: có ở đây.
#  - Lệnh bật timer: có, nhưng chỉ những timer có tên cố định.
#  - Lệnh thay đổi lớn (cutover switch/rollback, format ổ, restic init, install.sh): KHÔNG có ở đây.
#    Chủ nhà tự chạy sau khi duyệt, vì đó là ranh giới kiểm soát của người.
# sudo xoá biến môi trường, nên CONFIRM=YES hay HOMELAB_ETC không lọt qua được.

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config

BIN=$(dirname "$(readlink -f "$0")")
cmd=${1:-help}
arg=${2:-}

seed_status() {
  echo "== homelab-seed.service"
  systemctl show homelab-seed.service -p ActiveState -p SubState \
    -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ExecMainStatus
  echo "== seed.last_ok: $(cat "$HOMELAB_STATE/seed.last_ok" 2>/dev/null || echo chưa)"
  echo "== timer: $(systemctl is-enabled homelab-seed.timer 2>/dev/null)"
  echo "== dumps trên NAS:"
  ls -l "$NAS_MOUNT/$NAS_META_SUBDIR/dumps" 2>&1 | tail -6
  echo "== dung lượng NAS:"
  df -h "$NAS_MOUNT" | tail -1
}

seed_verify() {
  local n
  n=$(rsync -aHn --numeric-ids -i --exclude-from="$HOMELAB_ETC/excludes.txt" \
    "$PRIMARY/" "$NAS_MOUNT/$NAS_HOMELAB_SUBDIR/" | grep -v '^\.d\.\.t' | grep -c .)
  echo "Số mục khác nhau giữa $PRIMARY và NAS: $n"
}

case $cmd in
  seed-status) seed_status ;;
  seed-verify) seed_verify ;;
  enable-seed-timer) systemctl enable --now homelab-seed.timer && systemctl list-timers homelab-seed.timer --no-pager ;;
  discover) "$BIN/00-discover.sh" ;;
  nfs-test) "$BIN/setup-nfs.sh" test ;;
  cutover-status) "$BIN/cutover.sh" status ;;
  cutover-preflight) "$BIN/cutover.sh" preflight ;;
  nas-precheck)
    case $arg in before|rebuild|after) "$BIN/nas-precheck.sh" "$arg" ;; *) die "nas-precheck before|rebuild|after" ;; esac ;;
  monitor)
    case $arg in storage|nas-health) "$BIN/monitor.sh" "$arg" ;; *) die "monitor storage|nas-health" ;; esac ;;
  ups-status) upsc ups@localhost 2>&1 | grep -E 'battery\.(charge|runtime)|ups\.(status|load)' ;;
  ups-dry-run) "$BIN/nut-shutdown.sh" fsd --dry-run ;;
  logs)
    case $arg in seed|backup-local|backup-mac|maintain|monitor-storage|nas-health|restore-drill)
      journalctl -u "homelab-$arg.service" -n 80 --no-pager ;;
    *) die "logs seed|backup-local|backup-mac|maintain|monitor-storage|nas-health|restore-drill" ;; esac ;;
  timers) systemctl list-timers 'homelab-*' --all --no-pager ;;
  *)
    cat <<'EOF'
Dùng: sudo /opt/homelab/bin/homelab-ops.sh <lệnh>
  seed-status | seed-verify | enable-seed-timer
  discover | nfs-test
  cutover-status | cutover-preflight
  nas-precheck before|rebuild|after
  monitor storage|nas-health
  ups-status | ups-dry-run
  logs <seed|backup-local|backup-mac|maintain|monitor-storage|nas-health|restore-drill>
  timers
EOF
    ;;
esac
