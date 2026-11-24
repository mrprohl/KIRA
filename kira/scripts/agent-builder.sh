#!/usr/bin/env bash
# ============================================================================
# agent-builder.sh on|off – temporarily allow creating and sharing agents in LibreChat
#   on   AGENT_BUILDER=true: admins (and users) may create, share and publish agents
#   off  AGENT_BUILDER=false: back to normal operation (fixed agents only)
# Needed for the image agent (README). Regenerates config/librechat.yaml and restarts LibreChat.
# ============================================================================
set -euo pipefail
KIRA_DIR=/opt/kira
SETUP_ENV=$KIRA_DIR/env/setup.env

case "${1:-}" in
  on)  value=true ;;
  off) value=false ;;
  *) echo "Usage: $0 on|off" >&2; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo "Error: please run as root." >&2; exit 1; }
[ -f "$SETUP_ENV" ] || { echo "Error: $SETUP_ENV is missing – run setup.sh first." >&2; exit 1; }

if grep -q '^AGENT_BUILDER=' "$SETUP_ENV"; then
  sed -i "s/^AGENT_BUILDER=.*/AGENT_BUILDER=\"$value\"/" "$SETUP_ENV"
else
  printf 'AGENT_BUILDER="%s"\n' "$value" >> "$SETUP_ENV"
fi
export KIRA_DIR
python3 -I "$KIRA_DIR/scripts/librechat-config.py"
if [ "$(docker inspect -f '{{.State.Running}}' librechat 2>/dev/null)" = "true" ]; then
  # the groups' agent lists live in the database (e.g. the image agent after AGENT_ID is set); the image agent
  # is also moved to its own endpoint "Bild-Agent" – agent-groups.sh does both and restarts LibreChat
  bash "$KIRA_DIR/scripts/agent-groups.sh" --no-regenerate
  echo "Agent builder $1 – LibreChat is restarting (about 1 minute)."
else
  echo "Agent builder $1 – LibreChat is not running right now; the setting applies on the next start."
fi
[ "$value" = true ] && echo "Switch it off again afterwards: $0 off"
exit 0
