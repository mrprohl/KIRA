#!/usr/bin/env bash
# ============================================================================
# privacy-report.sh – counts of the privacy guard (kira/PRIVACY-GUARD.md) from the Bifrost log, output + Slack.
#   no argument: last 7 days (this is how cron runs it on Mondays)   ·   <hours>: e.g. 24 for the last day
# Counts only decisions and categories – the plugin never logs content. Report text in German (also sent to Slack).
# Note: the Docker log of Bifrost keeps about 50 MB (5 × 10 MB); with very many requests older lines are gone.
# ============================================================================
set -euo pipefail
. "$(dirname "$0")/lib.sh"

hours=${1:-168}
[[ $hours =~ ^[0-9]+$ ]] && [ "$hours" -ge 1 ] || { echo "Usage: $0 [hours]" >&2; exit 2; }
if [ "$(sed -n 's/^PRIVACY_GUARD=//p' "$KIRA_DIR/env/setup.env" | tail -1 | tr -d '"')" != "true" ]; then
  echo "Privacy guard is off (PRIVACY_GUARD in env/setup.env)."
  exit 0
fi

lines=$(docker logs --since "${hours}h" bifrost 2>&1 | grep -o 'privacy-guard mode=[a-z]* decision=.*' || true)
text=$(printf '%s\n' "$lines" | python3 -I -c '
import collections, re, sys
dec = collections.Counter(); cats = collections.defaultdict(collections.Counter); mode = set(); failed = 0
for line in sys.stdin:
    f = dict(re.findall(r"(\w+)=(\S+)", line))
    if "decision" not in f:
        continue
    mode.add(f.get("mode", "?"))
    d = f["decision"]; dec[d] += 1
    if f.get("failed") == "true":
        failed += 1
    src = f.get("categories", "-")
    if d == "refuse" and f.get("safety") == "unsafe":
        src = f.get("safety_categories", "-")
    for c in src.split(","):
        if c and c != "-":
            cats[d][c] += 1
names = {"external": "Nach außen (sauber)", "local": "Lokal beantwortet", "refuse": "Abgelehnt"}
total = sum(dec.values())
if not total:
    print("Keine Anfragen im Zeitraum."); sys.exit()
out = []
if "observe" in mode:
    out.append("Modus: beobachten – es wurde nichts umgeleitet, nur gezählt, was passiert wäre.")
for d in ("external", "local", "refuse"):
    detail = ", ".join(f"{c} {n}" for c, n in cats[d].most_common())
    out.append(f"{names[d]}: {dec[d]}" + (f" ({detail})" if detail else ""))
out.append(f"Prüfung fehlgeschlagen (lokal beantwortet): {failed}")
out.append(f"Gesamt: {total}")
print("\n".join(out))
')

label="letzte $((hours / 24)) Tage"; [ "$hours" -lt 48 ] && label="letzte $hours Stunden"
echo "KIRA – Datenschutzprüfung ($label)"
echo "$text"
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  slack ":shield: *KIRA – Datenschutzprüfung ($label)*
\`\`\`
$text
\`\`\`"
fi
