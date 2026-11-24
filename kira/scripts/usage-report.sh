#!/usr/bin/env bash
# ============================================================================
# usage-report.sh – costs per user (KIRA) and per virtual key from the Bifrost logs, output + Slack.
#   no argument:  previous month (this is how cron runs it on the 1st of the month)
#   current:      current month (by hand: /opt/kira/scripts/usage-report.sh current)
# Users come from the header x-librechat-user-email – only if SEND_USER_HEADERS=true (env/setup.env).
# Requests without a user header (e.g. Onyx, external services) appear with the name of the virtual key.
# ============================================================================
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# report text in German (also sent to Slack)
if [ "${1:-}" = "current" ]; then
  from="date_trunc('month', now())"; to="now()"; label="laufender Monat ($(date +%m/%Y))"
else
  from="date_trunc('month', now()) - interval '1 month'"; to="date_trunc('month', now())"
  label="Vormonat ($(date -d "$(date +%Y-%m-01) -1 day" +%m/%Y))"
fi

report=$(psql_bifrost "
  SELECT COALESCE(
           NULLIF(CASE WHEN l.metadata IS NOT NULL AND l.metadata <> '' THEN l.metadata::jsonb ->> 'x-librechat-user-email' END, ''),
           '[' || COALESCE(vk.name, l.virtual_key_id, 'ohne Key') || ']') AS who,
         count(*) AS requests,
         to_char(COALESCE(sum(l.cost), 0), 'FM999990.00') AS usd
    FROM logs l
    LEFT JOIN governance_virtual_keys vk ON vk.id = l.virtual_key_id
   WHERE l.\"timestamp\" >= $from AND l.\"timestamp\" < $to AND l.status = 'success'
   GROUP BY 1
   ORDER BY sum(l.cost) DESC NULLS LAST")

if [ -z "$report" ]; then
  text="Keine Anfragen im Zeitraum."
else
  text=$(printf '%s\n' "$report" | awk -F'|' '{ printf "%-40s %8s Anfr. %10s USD\n", $1, $2, $3; s += $3 } END { printf "%-40s %8s       %10.2f USD\n", "Summe", "", s }')
fi

echo "KIRA – Kosten $label"
echo "$text"
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  slack ":bar_chart: *KIRA – Kosten $label*
\`\`\`
$text
\`\`\`"
fi
