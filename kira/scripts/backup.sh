#!/usr/bin/env bash
# ============================================================================
# backup.sh – daily via cron (/etc/cron.d/kira), can also be run by hand:
#   Bifrost DB, LibreChat MongoDB, RAG vector database, Onyx DB (if active), LibreChat uploads/images and
#   /opt/{caddy,bifrost,kira,websearch,onyx,office} (incl. env/ – secrets!) to $BACKUP_DIR/<date_time>/,
#   kept for $BACKUP_KEEP_DAYS days. Result -> Uptime Kuma (push monitor "KIRA Backup"), errors also -> Slack.
# Not backed up (rebuilt automatically): Meilisearch index, Onyx OpenSearch index, Firecrawl queues.
# Restore: README, section "Operations".
# ============================================================================
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ts=$(date +%F_%H%M)
target="$BACKUP_DIR/$ts"

fail() {   # reason in German – it goes into the Slack message
  local msg="Backup $ts failed: $1"
  echo "$msg" >&2
  rm -rf "$target"            # do not leave an incomplete backup behind
  kuma_push "${KUMA_PUSH_BACKUP:-}" down "$msg"
  slack ":x: *KIRA – Backup $ts fehlgeschlagen:* $1 (Details: journalctl -t kira-backup)"   # Slack in German
  exit 1
}
trap 'fail "Fehler in Zeile $LINENO"' ERR

umask 077
mkdir -p "$target"
chmod 700 "$BACKUP_DIR"

# --- Bifrost (configuration, logs, budgets) ---
docker exec bifrost-db pg_dump -U postgres -Fc bifrost > "$target/bifrost.dump"
[ -s "$target/bifrost.dump" ] || fail "Dump Bifrost ist leer"

# --- LibreChat (MongoDB) ---
MONGO_USER=$(sed -n 's/^MONGO_INITDB_ROOT_USERNAME=//p' "$KIRA_DIR/env/mongodb.env")
MONGO_PW=$(sed -n 's/^MONGO_INITDB_ROOT_PASSWORD=//p' "$KIRA_DIR/env/mongodb.env")
docker exec librechat-mongodb mongodump --quiet --archive --gzip --db LibreChat \
  --username "$MONGO_USER" --password "$MONGO_PW" --authenticationDatabase admin > "$target/librechat-mongo.archive.gz"
[ -s "$target/librechat-mongo.archive.gz" ] || fail "Dump MongoDB ist leer"

# --- RAG (vectors of the uploaded documents) ---
docker exec librechat-vectordb sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$target/rag.dump"
[ -s "$target/rag.dump" ] || fail "Dump RAG ist leer"

# --- LibreChat files (uploads, generated images) ---
docker cp librechat:/app/uploads - | gzip > "$target/librechat-uploads.tar.gz"
docker cp librechat:/app/client/public/images - | gzip > "$target/librechat-images.tar.gz"

# --- Onyx (incl. uploaded files, FILE_STORE_BACKEND=postgres) ---
if [ "$ONYX_ENABLED" = "true" ]; then
  docker exec onyx-db sh -c 'pg_dump -U "$POSTGRES_USER" -Fc postgres' > "$target/onyx.dump"
  [ -s "$target/onyx.dump" ] || fail "Dump Onyx ist leer"
fi

# --- stack folders incl. secrets ---
dirs=()
for d in caddy bifrost kira websearch onyx office; do [ -d "/opt/$d" ] && dirs+=("$d"); done
tar czf "$target/opt-stacks.tgz" -C /opt "${dirs[@]}"

trap - ERR
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$BACKUP_KEEP_DAYS" -exec rm -rf {} +

size=$(du -sh "$target" | cut -f1)
kuma_push "${KUMA_PUSH_BACKUP:-}" up "OK $ts ($size)"
echo "Backup $ts done: $target ($size)"
