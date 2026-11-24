#!/usr/bin/env bash
# ============================================================================
# Shared functions for monitor.sh, backup.sh, usage-report.sh (included via "source")
# ============================================================================
KIRA_DIR=/opt/kira
# shellcheck source=/dev/null
. "$KIRA_DIR/env/monitoring.env"

ONYX_ENABLED=$(sed -n 's/^ONYX_ENABLED=//p' "$KIRA_DIR/env/setup.env" | tail -1 | tr -d '"')

# expected containers (container_name in the compose.yml files)
CONTAINERS=(caddy bifrost bifrost-db
            librechat librechat-mongodb librechat-meilisearch librechat-rag librechat-vectordb
            searxng firecrawl firecrawl-playwright firecrawl-redis firecrawl-rabbitmq firecrawl-nuq-postgres)
if [ "$ONYX_ENABLED" = "true" ]; then
  CONTAINERS+=(onyx-api onyx-background onyx-web onyx-mcp onyx-inference-model onyx-indexing-model
               onyx-db onyx-opensearch onyx-cache onyx-nginx)
fi
export CONTAINERS

# slack <text> – message to the Slack webhook (without webhook: print only); the URL goes via -K, not on the command line
slack() {
  if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    echo "$1"
    return 0
  fi
  python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$1" \
    | curl -fsS -m 15 -H 'Content-Type: application/json' -d @- -K <(printf 'url = "%s"\n' "$SLACK_WEBHOOK_URL") >/dev/null \
    || echo "Error: Slack message could not be sent." >&2
}

# kuma_push <push URL> <up|down> <message> – heartbeat to Uptime Kuma (without URL: nothing)
# KUMA_RESOLVE (env/monitoring.env): "host:443:ip" – reach Uptime Kuma internally instead of via the public IP
kuma_push() {
  [ -n "${1:-}" ] || return 0
  local msg host r
  local opts=()
  msg=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1][:200]))' "$3")
  for r in ${KUMA_RESOLVE:-}; do opts+=(--resolve "$r"); done
  host=${1#*://}; host=${host%%/*}
  # the push URL contains the token: passed via -K (not visible in the process list), only the host is logged
  curl -fsS -m 15 "${opts[@]}" -o /dev/null -K <(printf 'url = "%s"\n' "$1?status=$2&msg=$msg&ping=") \
    || echo "Error: Uptime Kuma push to $host failed${KUMA_RESOLVE:+ (KUMA_RESOLVE=$KUMA_RESOLVE)}." >&2
}

# psql_bifrost <SQL> – query the Bifrost database, output without header, columns separated by |
psql_bifrost() {
  docker exec bifrost-db psql -U postgres -d bifrost -v ON_ERROR_STOP=1 -AtF '|' -c "$1"
}
