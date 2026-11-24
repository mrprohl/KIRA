#!/usr/bin/env bash
# ============================================================================
# agent-groups.sh – apply agents per Keycloak group in LibreChat
#   Reads config/agent-groups.json (generated from agents/groups.env by librechat-config.py), creates one
#   LibreChat role with its own agent list per group, switches the role sync with Keycloak ("groups" claim)
#   on or off and restarts LibreChat.
#   Called by setup.sh; manually: bash /opt/kira/scripts/agent-groups.sh
# ============================================================================
set -euo pipefail
KIRA_DIR=/opt/kira
PLAN=$KIRA_DIR/config/agent-groups.json
STATE=$KIRA_DIR/config/agent-groups.state.json
LC_ENV=$KIRA_DIR/env/librechat.env

[ "$(id -u)" = 0 ] || { echo "Error: please run as root." >&2; exit 1; }
export KIRA_DIR
[ "${1:-}" = "--no-regenerate" ] || python3 -I "$KIRA_DIR/scripts/librechat-config.py" >/dev/null
[ -f "$PLAN" ] || { echo "Error: $PLAN is missing – run bash $KIRA_DIR/setup.sh first" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' librechat 2>/dev/null)" = "true" ] \
  || { echo "Error: LibreChat is not running – start the stacks, then run this again." >&2; exit 1; }

# plan + groups that existed on the last run and are gone now (they are removed)
read -r PAYLOAD SYNC_ON PRIORITY REQUIRED ADMIN_GROUP < <(python3 -I - "$PLAN" "$STATE" <<'PY'
import base64, json, os, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
old = json.load(open(sys.argv[2], encoding="utf-8")) if os.path.exists(sys.argv[2]) else {}
now = set(plan.get("roles", {})) if plan.get("enabled") else set()
plan["remove"] = sorted(set(old.get("roles", {}) if old.get("enabled") else {}) - now)
payload = base64.b64encode(json.dumps(plan, ensure_ascii=False).encode()).decode()
required = ",".join(plan.get("priority", []) + [plan.get("admin_group", "")]).strip(",") or "-"
print(payload, "true" if plan.get("enabled") else "false", ",".join(plan.get("priority", [])) or "-", required,
      plan.get("admin_group") or "-")
PY
)

echo "Applying agents per group in LibreChat …"
# the plan travels on stdin in front of the script (not as -e variable: role lists with prompts and icons
# can exceed the kernel limit of 128 KB per argument)
{ printf "'use strict';\nprocess.env.KIRA_PLAN = '%s';\n" "$PAYLOAD"; cat "$KIRA_DIR/scripts/agent-groups.js"; } \
  | docker exec -i -w /app librechat node -

# role sync with Keycloak: "groups" claim in the ID token → LibreChat role; the admin group → ADMIN
env_set() {   # env_set <variable> <value>
  local tmp; tmp=$(mktemp "$LC_ENV.XXXXXX")
  awk -v k="$1" -v v="$2" 'BEGIN{d=0} $0 ~ "^" k "=" {if(!d){print k "=\"" v "\""; d=1}; next} {print} END{if(!d) print k "=\"" v "\""}' \
    "$LC_ENV" > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$LC_ENV"
}
before=$(sha256sum "$LC_ENV" | cut -d' ' -f1)
if [ "$SYNC_ON" = true ]; then
  env_set OPENID_ROLE_SYNC_ENABLED true
  env_set OPENID_ROLE_SYNC_SOURCE id
  env_set OPENID_ROLE_SYNC_CLAIM groups
  env_set OPENID_ROLE_SYNC_ROLE_PRIORITY "$PRIORITY"
  env_set OPENID_ROLE_SYNC_FALLBACK_ROLE USER
  # login only with one of the groups (incl. the admin group) in the "groups" claim
  env_set OPENID_REQUIRED_ROLE "$REQUIRED"
  env_set OPENID_REQUIRED_ROLE_PARAMETER_PATH groups
  env_set OPENID_REQUIRED_ROLE_TOKEN_KIND id
  # admins = members of the admin group (instead of the client role "admin"); see all agents
  env_set OPENID_ADMIN_ROLE "$ADMIN_GROUP"
  env_set OPENID_ADMIN_ROLE_PARAMETER_PATH groups
  env_set OPENID_ADMIN_ROLE_TOKEN_KIND id
else
  env_set OPENID_ROLE_SYNC_ENABLED false
  env_set OPENID_REQUIRED_ROLE user,admin
  env_set OPENID_REQUIRED_ROLE_PARAMETER_PATH roles
  env_set OPENID_REQUIRED_ROLE_TOKEN_KIND id
  env_set OPENID_ADMIN_ROLE admin
  env_set OPENID_ADMIN_ROLE_PARAMETER_PATH roles
  env_set OPENID_ADMIN_ROLE_TOKEN_KIND id
fi
after=$(sha256sum "$LC_ENV" | cut -d' ' -f1)

if [ "$before" != "$after" ]; then
  echo "Role sync changed – recreating LibreChat (about 1 minute)."
  docker compose -f "$KIRA_DIR/docker-compose.yml" up -d librechat >/dev/null
else
  echo "Restarting LibreChat (reloading agent lists, about 1 minute)."
  docker restart librechat >/dev/null
fi
install -m 644 "$PLAN" "$STATE"
if [ "$SYNC_ON" = true ]; then
  echo "Done. The mapping applies from the next login (users who are logged in: log out and in again)."
else
  echo "Done. Agents per group is off – all users see all agents from librechat.yaml again."
fi
