#!/usr/bin/env bash
# ============================================================================
# monitor.sh – every 5 minutes via cron (/etc/cron.d/kira):
#   1. health of all containers (and of the LAN block, if enabled) -> Uptime Kuma (push monitor "KIRA Container")
#   2. budget usage of the virtual keys in Bifrost -> Slack, once per threshold and budget time window
# ============================================================================
set -euo pipefail
. "$(dirname "$0")/lib.sh"

STATE_DIR=/var/lib/kira-monitor
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

# --- 1. Container health ---
problems=()
for c in "${CONTAINERS[@]}"; do
  state=$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$c" 2>/dev/null) \
    || state="missing"
  case "$state" in
    running/healthy|running/no-healthcheck|running/starting) ;;
    *) problems+=("$c: $state") ;;
  esac
done
LAN_BLOCK=$(sed -n 's/^LAN_BLOCK=//p' "$KIRA_DIR/env/setup.env" | tail -1 | tr -d '"')
if [ "$LAN_BLOCK" = "true" ] && ! "$KIRA_DIR/scripts/egress-firewall.sh" status -q >/dev/null 2>&1; then
  problems+=("LAN block missing (systemctl restart kira-egress-firewall)")
fi
if [ ${#problems[@]} -eq 0 ]; then
  kuma_push "${KUMA_PUSH_HEALTH:-}" up "OK (${#CONTAINERS[@]} containers)"
else
  msg=$(IFS='; '; echo "${problems[*]}")
  kuma_push "${KUMA_PUSH_HEALTH:-}" down "$msg"
  echo "Container problems: $msg" >&2
fi

# --- 2. Budget warnings (only with Slack; Slack messages in German) ---
[ -n "${SLACK_WEBHOOK_URL:-}" ] || exit 0
# Bifrost writes usage to the database with a delay – a warning may lag a few minutes behind.
if ! budgets=$(psql_bifrost "SELECT id, max_limit, current_usage, last_reset, reset_duration FROM governance_budgets ORDER BY id" 2>/dev/null); then
  echo "Budgets not readable (database unreachable?)." >&2
  exit 0
fi
window_label() {   # German label for the Slack message: 5h -> "5 Stunden", 1w -> "Woche", 1M -> "Monat" …
  case "$1" in
    1h) echo "Stunde" ;;  *h) echo "${1%h} Stunden" ;;
    1d) echo "Tag" ;;     *d) echo "${1%d} Tage" ;;
    1w) echo "Woche" ;;   *w) echo "${1%w} Wochen" ;;
    1M) echo "Monat" ;;   *M) echo "${1%M} Monate" ;;
    *)  echo "$1" ;;
  esac
}
while IFS='|' read -r id max usage last_reset duration; do
  [ -n "$id" ] || continue
  pct=$(python3 -c 'import sys; m=float(sys.argv[1]); print(int(float(sys.argv[2])*100/m) if m>0 else 0)' "$max" "$usage")
  case "$duration" in
    *s|*m|*h|*d) thresholds=${BUDGET_ALERT_THRESHOLDS_SHORT:-100} ;;
    *)           thresholds=${BUDGET_ALERT_THRESHOLDS:-"80 100"} ;;
  esac
  window=$(window_label "$duration")
  for thr in $thresholds; do
    [ "$pct" -ge "$thr" ] || continue
    marker="$STATE_DIR/$(printf '%s_%s_%s' "$id" "$thr" "$last_reset" | tr -c 'A-Za-z0-9_.-' '_')"
    [ -e "$marker" ] && continue
    usage_fmt=$(printf '%.2f' "$usage"); max_fmt=$(printf '%.2f' "$max")
    if [ "$thr" -ge 100 ]; then
      slack ":no_entry: *KIRA – Budget aufgebraucht ($window):* \`$id\` hat $usage_fmt von $max_fmt USD verbraucht ($pct %). Anfragen mit diesem Key werden abgelehnt (HTTP 402), bis das Zeitfenster neu beginnt. Erhöhen: \`max_limit\` in /opt/bifrost/config/bifrost.json, dann docker restart bifrost."
    else
      slack ":warning: *KIRA – Budget-Warnung ($window):* \`$id\` hat $pct % verbraucht ($usage_fmt von $max_fmt USD)."
    fi
    touch "$marker"
  done
done <<< "$budgets"

# clean up old markers
find "$STATE_DIR" -type f -mtime +100 -delete 2>/dev/null || true
