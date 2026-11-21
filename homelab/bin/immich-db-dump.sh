#!/usr/bin/env bash
# Dump toàn bộ Postgres của Immich ra DUMP_DIR (trên NVMe), giữ 14 bản mới nhất.
# Được các script backup gọi trước khi chạy; cũng chạy tay được.

. "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_config
require_vars IMMICH_DB_CONTAINER IMMICH_DB_USER DUMP_DIR

mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"
docker inspect -f '{{.State.Running}}' "$IMMICH_DB_CONTAINER" 2>/dev/null | grep -q true \
  || die "Container $IMMICH_DB_CONTAINER không chạy."

out="$DUMP_DIR/immich-$(date +%Y%m%d-%H%M%S).sql.gz"
log "Dump Immich DB → $out"
if ! docker exec "$IMMICH_DB_CONTAINER" pg_dumpall --clean --if-exists --username="$IMMICH_DB_USER" \
  | gzip >"$out.part"; then
  rm -f "$out.part"
  die "pg_dumpall thất bại."
fi
gzip -t "$out.part" || { rm -f "$out.part"; die "File dump hỏng."; }
mv "$out.part" "$out"
log "Dump xong: $(du -h "$out" | cut -f1)"

# Giữ 14 bản mới nhất
find "$DUMP_DIR" -maxdepth 1 -name 'immich-*.sql.gz' -printf '%T@ %p\n' \
  | sort -rn | tail -n +15 | cut -d' ' -f2- | xargs -r rm -f
