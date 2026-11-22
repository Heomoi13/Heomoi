#!/usr/bin/env bash
# GIAI ĐOẠN 4 — Chuyển dữ liệu gốc từ HDD server sang NAS.
#
# Ý tưởng: GIỮ NGUYÊN đường dẫn /srv/nas. Sau cutover:
#   - /srv/nas        = mount NFS  NAS:/volume1/data/homelab   (dữ liệu gốc)
#   - /mnt/old-hdd    = ổ HDD 3TB cũ, chỉ đọc (đường lui 2–4 tuần)
# Mọi container và cron dùng /srv/nas không phải sửa cấu hình.
#
# Lệnh:
#   cutover.sh status
#   cutover.sh preflight             — kiểm tra, không thay đổi gì
#   cutover.sh sync                  — chép phần chênh lệch khi dịch vụ vẫn chạy (an toàn, lặp lại được)
#   CONFIRM=YES cutover.sh switch    — dừng dịch vụ, chép lần cuối, kiểm tra, đổi mount, chạy lại
#   CONFIRM=YES cutover.sh rollback  — quay về HDD cũ (chép ngược file mới về trước)
# Biến tuỳ chọn: VERIFY=checksum (mặc định, chậm nhưng chắc) | VERIFY=quick
#                ACK_SQLITE=yes — người đã xem danh sách file SQLite trong /srv/nas và chấp nhận

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars PRIMARY OLD_HDD_MOUNT NAS_IP NAS_NFS_EXPORT NAS_HOMELAB_SUBDIR NAS_MOUNT NFS_OPTS

CMD=${1:-status}
DEST="$NAS_MOUNT/$NAS_HOMELAB_SUBDIR"
NFS_SRC="$NAS_IP:$NAS_NFS_EXPORT/$NAS_HOMELAB_SUBDIR"
STATE=$HOMELAB_STATE/cutover.state
CONTAINERS_FILE=$HOMELAB_STATE/cutover-containers.txt
FSTAB_MARK="# homelab:primary-nfs (dữ liệu gốc trên NAS)"
VERIFY=${VERIFY:-checksum}

need_confirm() { [[ ${CONFIRM:-} == YES ]] || die "Lệnh '$CMD' thay đổi hệ thống. Chạy lại với CONFIRM=YES sau khi người đã đồng ý."; }

# Container có mount nằm trong PRIMARY, cộng tất cả container cùng compose project.
affected_containers() {
  local id name projects=() p
  for id in $(docker ps -q); do
    if docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$id" \
      | grep -qE "^${PRIMARY}(/|$)"; then
      p=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id")
      name=$(docker inspect -f '{{.Name}}' "$id"); echo "${name#/}"
      [[ -n $p ]] && projects+=("$p")
    fi
  done
  for p in $(printf '%s\n' "${projects[@]}" | sort -u); do
    docker ps --filter "label=com.docker.compose.project=$p" --format '{{.Names}}'
  done
} 2>/dev/null

# Dịch vụ host cũng giữ file trong PRIMARY (Samba share, cron job đọc dữ liệu) → dừng cùng lúc.
SERVICES_FILE=$HOMELAB_STATE/cutover-services.txt
stop_services() {
  : >"$SERVICES_FILE"
  local s
  for s in ${CUTOVER_STOP_SERVICES:-}; do
    if systemctl is-active --quiet "$s"; then
      systemctl stop "$s" && echo "$s" >>"$SERVICES_FILE" && log "Đã dừng dịch vụ $s"
    fi
  done
}

start_services() {
  [[ -s $SERVICES_FILE ]] || return 0
  local s
  while read -r s; do systemctl start "$s" && log "Đã chạy lại dịch vụ $s"; done <"$SERVICES_FILE"
}

# Cờ bảo trì: script giám sát khác (vd. job tự restart container của Hermes) PHẢI bỏ qua khi file này tồn tại.
# Bài học 22/11/2026: một job giám sát đã bật lại container giữa lúc đang kiểm tra checksum.
MAINT_FLAG=/run/homelab-maintenance

stop_containers() {
  echo "cutover $CMD từ $(date '+%F %T') — không tự khởi động lại container" >"$MAINT_FLAG"
  stop_services
  affected_containers | sort -u >"$CONTAINERS_FILE"
  log "Dừng $(wc -l <"$CONTAINERS_FILE") container: $(tr '\n' ' ' <"$CONTAINERS_FILE")"
  [[ -s $CONTAINERS_FILE ]] && xargs -r docker stop -t 60 <"$CONTAINERS_FILE" >/dev/null
}

# In ra tên các container trong danh sách đã dừng mà nay lại đang chạy.
containers_restarted() {
  local c
  while read -r c; do
    [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]] && echo "$c"
  done <"$CONTAINERS_FILE"
}

start_containers() {
  rm -f "$MAINT_FLAG"
  start_services
  [[ -s $CONTAINERS_FILE ]] || return 0
  log "Khởi động lại: $(tr '\n' ' ' <"$CONTAINERS_FILE")"
  xargs -r docker start <"$CONTAINERS_FILE" >/dev/null || log "Một số container không khởi động được — kiểm tra docker ps -a"
}

preflight() {
  local fail=0
  log "=== Preflight ==="
  if is_nfs_mount "$PRIMARY"; then log "  ❌ $PRIMARY đã là NFS — cutover đã làm rồi."; return 1; fi
  mountpoint -q "$PRIMARY" && log "  ✅ $PRIMARY đang mount từ $(findmnt -n -o SOURCE "$PRIMARY")" \
    || { log "  ❌ $PRIMARY chưa mount"; fail=1; }
  nas_dest_ready && log "  ✅ Đích $DEST sẵn sàng, có sentinel" || { log "  ❌ Đích NAS chưa sẵn sàng"; fail=1; }

  local used avail
  used=$(df -B1 --output=used "$PRIMARY" | tail -1)
  avail=$(df -B1 --output=avail "$NAS_MOUNT" | tail -1)
  local already
  already=$(du -sxb "$DEST" 2>/dev/null | cut -f1)
  if ((avail + ${already:-0} > used * 11 / 10)); then
    log "  ✅ Đủ chỗ trên NAS: cần ~$(numfmt --to=iec "$used"), trống $(numfmt --to=iec "$avail") (đã có $(numfmt --to=iec "${already:-0}"))"
  else
    log "  ❌ Không đủ chỗ trên NAS"; fail=1
  fi

  local n
  n=$(awk -v p="$PRIMARY" '!/^[[:space:]]*#/ && $2==p' /etc/fstab | wc -l)
  ((n == 1)) && log "  ✅ /etc/fstab có đúng 1 dòng cho $PRIMARY" || { log "  ❌ /etc/fstab có $n dòng cho $PRIMARY (cần đúng 1)"; fail=1; }

  # Postgres tuyệt đối không được nằm trên NFS
  local pg
  pg=$(for id in $(docker ps -aq); do
    docker inspect -f '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' "$id"
  done 2>/dev/null | awk -v p="$PRIMARY" 'index($1, p"/")==1 && $2 ~ /postgres/')
  [[ -z $pg ]] && log "  ✅ Không có dữ liệu Postgres trong $PRIMARY" \
    || { log "  ❌ Dữ liệu Postgres nằm trong $PRIMARY: $pg → làm bước 4.1 trước"; fail=1; }

  local sq
  sq=$(find "$PRIMARY" -xdev \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) 2>/dev/null | head -20)
  if [[ -n $sq ]]; then
    if [[ ${ACK_SQLITE:-} == yes ]]; then
      log "  ⚠️  Có file SQLite trong $PRIMARY (người đã chấp nhận, ACK_SQLITE=yes)"
    else
      log "  ❌ Có file SQLite trong $PRIMARY, cần người quyết định (đặt ACK_SQLITE=yes nếu chấp nhận):"
      printf '       %s\n' "$sq" >&2
      fail=1
    fi
  else
    log "  ✅ Không có file SQLite trong $PRIMARY"
  fi

  if pgrep -x rsync >/dev/null; then log "  ❌ Đang có rsync khác chạy (backup?) — chờ xong"; fail=1; fi
  if [[ -f $HOMELAB_STATE/seed.last_ok ]]; then
    log "  ✅ Seed gần nhất: $(cat "$HOMELAB_STATE/seed.last_ok")"
  else
    log "  ⚠️  Chưa có seed thành công — lần switch sẽ rất lâu"
  fi
  command -v chattr >/dev/null || { log "  ❌ Thiếu chattr"; fail=1; }
  log "  Container sẽ bị dừng khi switch: $(affected_containers | sort -u | tr '\n' ' ')"
  log "  Dịch vụ host sẽ bị dừng: ${CUTOVER_STOP_SERVICES:-không có}"
  ((fail == 0)) && log "PREFLIGHT: ĐẠT" || log "PREFLIGHT: KHÔNG ĐẠT"
  return $fail
}

do_rsync() { # do_rsync <thêm tuỳ chọn...>
  rsync -aH --numeric-ids --exclude-from="$HOMELAB_ETC/excludes.txt" "$@" "$PRIMARY/" "$DEST/"
}

# Đưa hệ thống về bố cục cũ (HDD ở PRIMARY). Dùng khi switch lỗi giữa chừng hoặc rollback.
restore_old_layout() {
  local bak=$1
  log "Khôi phục bố cục cũ từ $bak"
  mountpoint -q "$PRIMARY" && umount "$PRIMARY"
  mountpoint -q "$OLD_HDD_MOUNT" && umount "$OLD_HDD_MOUNT"
  cp -a "$bak" /etc/fstab
  chattr -i "$PRIMARY" 2>/dev/null
  systemctl daemon-reload
  mount "$PRIMARY" || die "KHÔNG mount lại được $PRIMARY — cần người xử lý ngay."
  is_nfs_mount "$PRIMARY" && die "Bất thường: $PRIMARY vẫn là NFS."
  log "Đã về bố cục cũ."
}

switch() {
  need_confirm
  take_lock nas-sync
  preflight || die "Preflight không đạt."
  tg_send "🔁 Bắt đầu cutover dữ liệu gốc sang NAS. Immich và các dịch vụ liên quan tạm dừng."

  stop_containers
  systemctl stop homelab-seed.timer 2>/dev/null

  log "Chép lần cuối (có --delete để NAS là bản sao y hệt)..."
  local itemlog=$HOMELAB_LOG_DIR/cutover-final-$(date +%Y%m%d-%H%M).log
  do_rsync --delete --itemize-changes --info=stats2 >"$itemlog" 2>&1
  local rc=$?
  if ((rc != 0)); then start_containers; die "rsync lần cuối lỗi (mã $rc). Dịch vụ đã chạy lại trên HDD. Log: $itemlog"; fi
  log "Số mục bị xoá trên NAS (có ở NAS nhưng không còn ở HDD): $(grep -c '^\*deleting' "$itemlog")"

  log "Kiểm tra lại (VERIFY=$VERIFY)..."
  local vopt=() diff
  [[ $VERIFY == checksum ]] && vopt=(--checksum)
  diff=$(do_rsync --delete -n -i "${vopt[@]}" 2>&1 | grep -v '^\.d\.\.t' | grep -c .)
  if ((diff != 0)); then
    start_containers
    die "Còn $diff khác biệt giữa HDD và NAS sau khi chép. Đã chạy lại dịch vụ trên HDD. Không đổi mount."
  fi
  log "  ✅ HDD và NAS khớp hoàn toàn."

  local bak
  bak=/etc/fstab.homelab-cutover-$(date +%Y%m%d-%H%M%S)
  cp -a /etc/fstab "$bak"
  echo "$bak" >"$HOMELAB_STATE/cutover.fstab_backup"

  # Container bị thứ khác bật lại trong lúc kiểm tra → dữ liệu có thể đã thay đổi sau khi so sánh,
  # và gỡ ổ khi container còn giữ mount cũ sẽ làm chúng tiếp tục ghi vào HDD. Huỷ an toàn.
  local back
  back=$(containers_restarted | tr '\n' ' ')
  if [[ -n $back ]]; then
    start_containers
    die "Container bị khởi động lại giữa chừng: $back— huỷ cutover, chưa đổi gì. Tắt job tự restart rồi chạy lại sync + switch."
  fi

  log "Gỡ HDD khỏi $PRIMARY"
  if ! umount "$PRIMARY"; then
    fuser -vm "$PRIMARY" 2>&1 | head -20 >&2
    start_containers
    die "Không gỡ được $PRIMARY (đang có tiến trình dùng). Đã chạy lại dịch vụ."
  fi
  # Khoá thư mục rỗng: nếu NFS không mount, không gì ghi nhầm vào ổ hệ thống được
  chattr +i "$PRIMARY"

  # Sửa fstab: dòng HDD chuyển sang OLD_HDD_MOUNT, chỉ đọc, nofail; thêm dòng NFS
  awk -v p="$PRIMARY" -v o="$OLD_HDD_MOUNT" 'BEGIN{OFS="\t"}
    !/^[[:space:]]*#/ && $2==p { $2=o; $4=$4",ro,nofail" } {print}' "$bak" >/etc/fstab.new
  {
    echo "$FSTAB_MARK"
    # Sau mất điện, server và NAS khởi động cùng lúc; server lên nhanh hơn → thử lại tới 5 phút chờ NAS.
    echo "$NFS_SRC $PRIMARY nfs $NFS_OPTS,_netdev,retry=5,x-systemd.mount-timeout=360 0 0"
  } >>/etc/fstab.new
  mv /etc/fstab.new /etc/fstab
  mkdir -p "$OLD_HDD_MOUNT"
  systemctl daemon-reload

  if ! mount "$OLD_HDD_MOUNT" || ! mount "$PRIMARY" || ! primary_on_nas; then
    log "Mount mới thất bại — tự động quay về bố cục cũ."
    restore_old_layout "$bak"
    start_containers
    die "Cutover thất bại ở bước mount, hệ thống đã về như cũ."
  fi
  log "  ✅ $PRIMARY giờ là NFS từ $NFS_SRC; HDD cũ ở $OLD_HDD_MOUNT (chỉ đọc)."

  start_containers
  systemctl disable --now homelab-seed.timer 2>/dev/null
  date '+%F %T' >"$STATE"
  tg_send "✅ Cutover xong: dữ liệu gốc đã nằm trên NAS. HDD cũ giữ chỉ đọc ở $OLD_HDD_MOUNT."
  log "CUTOVER HOÀN TẤT. Kiểm tra Immich, Syncthing, Calibre theo README bước 4.4."
}

rollback() {
  need_confirm
  take_lock nas-sync
  [[ -f $STATE ]] || die "Không thấy trạng thái cutover — không có gì để rollback."
  local bak
  bak=$(cat "$HOMELAB_STATE/cutover.fstab_backup")
  [[ -f $bak ]] || die "Thiếu bản sao fstab $bak"
  primary_on_nas || die "$PRIMARY hiện không phải NFS — kiểm tra tay."
  tg_send "↩️ Đang rollback: đưa dữ liệu gốc về HDD server."

  stop_containers

  log "Chép các file mới từ NAS về HDD (không xoá gì trên HDD)..."
  mount -o remount,rw "$OLD_HDD_MOUNT" || die "Không remount rw được $OLD_HDD_MOUNT"
  rsync -aH --numeric-ids --info=stats2 --exclude-from="$HOMELAB_ETC/excludes.txt" \
    "$PRIMARY/" "$OLD_HDD_MOUNT/" || die "rsync ngược thất bại — dừng, cần người xử lý."

  restore_old_layout "$bak"
  start_containers
  rm -f "$STATE"
  tg_send "↩️ Rollback xong: dữ liệu gốc trở lại HDD server. Bật lại homelab-seed.timer nếu cần."
}

status() {
  echo "PRIMARY      : $(findmnt -n -o SOURCE,FSTYPE "$PRIMARY" 2>/dev/null || echo 'không mount')"
  echo "OLD_HDD      : $(findmnt -n -o SOURCE,FSTYPE,OPTIONS "$OLD_HDD_MOUNT" 2>/dev/null || echo 'không mount')"
  echo "Sentinel     : $([[ -f $PRIMARY/$SENTINEL ]] && echo có || echo không)"
  echo "Cutover lúc  : $(cat "$STATE" 2>/dev/null || echo chưa)"
  echo "Seed gần nhất: $(cat "$HOMELAB_STATE/seed.last_ok" 2>/dev/null || echo chưa)"
}

case $CMD in
  status) status ;;
  preflight) preflight ;;
  sync)
    take_lock nas-sync
    preflight || die "Preflight không đạt."
    do_rsync --info=progress2,stats2
    ;;
  switch) switch ;;
  rollback) rollback ;;
  *) die "Dùng: $0 status|preflight|sync|switch|rollback" ;;
esac
