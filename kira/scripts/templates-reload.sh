#!/usr/bin/env bash
# ============================================================================
# templates-reload.sh – the template skills (vorlagen-<agent>, stack docs) take effect in LibreChat
#
# docs-sync writes them every 15 minutes to /opt/docs/skills/live; LibreChat reads that folder only when it starts.
# This script restarts LibreChat if the skills changed since the last restart (chats that are running are cut off –
# hence at night via cron, /etc/cron.d/kira). setup.sh calls it after starting the stacks.
#
#   templates-reload.sh            restart LibreChat if the skills changed
#   templates-reload.sh --quiet    the same, but no output when nothing changed (cron)
#   templates-reload.sh --status   only show whether a restart is pending (exit 1 = pending)
# ============================================================================
set -euo pipefail
LIVE=/opt/docs/skills/live
STAMP=/opt/kira/config/templates.sha256

[ "$(id -u)" = 0 ] || { echo "Error: please run as root." >&2; exit 1; }
[ -d "$LIVE" ] && [ ! -L "$LIVE" ] && [ ! -L "${LIVE%/*}" ] \
  || { echo "Error: $LIVE is missing or not a plain folder – run bash /opt/kira/setup.sh." >&2; exit 1; }

current=$( { cd "$LIVE" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum; } | sha256sum | cut -c1-64)
skills=$(find "$LIVE" -mindepth 2 -maxdepth 2 -name SKILL.md -printf '%h\n' | xargs -r -n1 basename | sort | tr '\n' ' ')

if [ "$current" = "$(cat "$STAMP" 2>/dev/null || true)" ]; then
  [ "${1:-}" = "--quiet" ] || echo "Template skills unchanged (${skills:-none})."
  exit 0
fi
if [ "${1:-}" = "--status" ]; then
  echo "Template skills changed – LibreChat restart pending (${skills:-none})."
  exit 1
fi
if [ "$(docker inspect -f '{{.State.Running}}' librechat 2>/dev/null)" != "true" ]; then
  echo "LibreChat is not running – the skills take effect when it starts."
  exit 0
fi
echo "Template skills changed (${skills:-none}) – restarting LibreChat …"
docker restart librechat >/dev/null
(umask 022; echo "$current" > "$STAMP")
# LibreChat refuses to start on an invalid skill – check that it stays up
for _ in $(seq 12); do
  sleep 5
  if [ "$(docker inspect -f '{{.State.Restarting}}' librechat 2>/dev/null)" = "true" ] \
     || [ "$(docker inspect -f '{{.State.Running}}' librechat 2>/dev/null)" != "true" ]; then
    echo "Error: LibreChat does not stay up after loading the skills – docker logs librechat 2>&1 | grep -i skill" >&2
    echo "  Quick fix: set TEMPLATES=false for the agent, run bash /opt/kira/setup.sh (docs/README.md)." >&2
    exit 1
  fi
done
echo "LibreChat restarted."
