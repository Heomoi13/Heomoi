#!/usr/bin/env bash
# Dump các Postgres chạy trong Docker ra DUMP_DIR (trên SSD), giữ 14 bản mới nhất cho mỗi DB.
# Danh sách lấy từ DB_DUMPS="container:user container:user" trong homelab.env.
# Backup dùng file dump thay vì chép thô thư mục dữ liệu Postgres (chép thô khi DB đang chạy có thể hỏng).
# Được các script backup gọi trước khi chạy; cũng chạy tay được.

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars DB_DUMPS DUMP_DIR

mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"
fail=0

for entry in $DB_DUMPS; do
  c=${entry%%:*} u=${entry#*:}
  if ! docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
    log "❌ Container $c không chạy — bỏ qua"; fail=1; continue
  fi
  out="$DUMP_DIR/$c-$(date +%Y%m%d-%H%M%S).sql.gz"
  if docker exec "$c" pg_dumpall --clean --if-exists --username="$u" | gzip >"$out.part" \
    && gzip -t "$out.part"; then
    mv "$out.part" "$out"
    log "✅ $c → $(basename "$out") ($(du -h "$out" | cut -f1))"
  else
    rm -f "$out.part"; log "❌ Dump $c thất bại"; fail=1; continue
  fi
  find "$DUMP_DIR" -maxdepth 1 -name "$c-*.sql.gz" -printf '%T@ %p\n' \
    | sort -rn | tail -n +15 | cut -d' ' -f2- | xargs -r rm -f
done

exit $fail
