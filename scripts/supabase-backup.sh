#!/bin/sh
# Nightly read-only backup of the Supabase Postgres DB, run via systemd timer
# (deploy/supabase-backup.service + .timer) on the Hostinger VPS. Only ever
# reads from Postgres (pg_dump) — never touches n8n or any other service.
#
# ponytail: schema allowlist (public + supabase_migrations) hardcoded, not a
# discovered list — extend --schema= flags below if new schemas matter.
set -eu

ENV_FILE="${SUPABASE_BACKUP_ENV:-/root/.supabase-backup.env}"
BACKUP_DIR="${SUPABASE_BACKUP_DIR:-/root/backups/supabase}"
IMAGE="postgres:17-alpine"
KEEP=14

set -a
. "$ENV_FILE"
set +a

mkdir -p "$BACKUP_DIR"
LOG="$BACKUP_DIR/backup.log"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMP_NAME="supabase-$STAMP.dump"
SQL_NAME="supabase-$STAMP.schema.sql.gz"
ERR_FILE="$BACKUP_DIR/.last-dump-err"

fail() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL $1" >>"$LOG"
    echo "$1" >&2
    exit 1
}

run_pg_dump() {
    # $1 = extra --schema= arg (may be empty)
    docker run --rm --env-file "$ENV_FILE" -e PGSSLMODE=require \
        -v "$BACKUP_DIR:/out" "$IMAGE" \
        pg_dump --no-password --format=custom --no-owner --no-privileges \
        --schema=public $1 -f "/out/$DUMP_NAME"
}

# Try including supabase_migrations; if this role can't dump it, drop it and note that.
NOTE=""
if ! run_pg_dump "--schema=supabase_migrations" 2>"$ERR_FILE"; then
    if grep -qi supabase_migrations "$ERR_FILE" 2>/dev/null; then
        NOTE=" (schema supabase_migrations skipped: not dumpable by this role)"
        run_pg_dump "" || fail "pg_dump failed even without supabase_migrations"
    else
        cat "$ERR_FILE" >&2
        fail "pg_dump failed"
    fi
fi
rm -f "$ERR_FILE"

# Schema-only plain SQL dump, gzipped, for human-readable diffing.
docker run --rm --env-file "$ENV_FILE" -e PGSSLMODE=require \
    -v "$BACKUP_DIR:/out" "$IMAGE" sh -c \
    "pg_dump --no-password --schema-only --no-owner --no-privileges --schema=public | gzip" \
    >"$BACKUP_DIR/$SQL_NAME" || fail "schema-only dump failed"

# Verify the custom-format dump is restorable and non-empty.
ENTRIES=$(docker run --rm -v "$BACKUP_DIR:/out" "$IMAGE" pg_restore --list "/out/$DUMP_NAME" | grep -c '^[0-9]')
if [ "$ENTRIES" -le 0 ]; then
    fail "pg_restore --list reports 0 entries in $DUMP_NAME"
fi

SIZE=$(du -h "$BACKUP_DIR/$DUMP_NAME" | cut -f1)

# Rotate: keep the 14 newest .dump files (and their matching schema dump).
cd "$BACKUP_DIR"
ls -1t supabase-*.dump 2>/dev/null | tail -n "+$((KEEP + 1))" | while read -r old; do
    rm -f "$old" "${old%.dump}.schema.sql.gz"
done

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) OK $DUMP_NAME size=$SIZE entries=$ENTRIES$NOTE" >>"$LOG"
