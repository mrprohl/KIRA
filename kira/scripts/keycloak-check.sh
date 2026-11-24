#!/usr/bin/env bash
# ============================================================================
# keycloak-check.sh – diagnosis for builder-sync.py (Keycloak service account, read-only)
#   bash /opt/kira/scripts/keycloak-check.sh
#   Gets a token for the service account (env/keycloak-sync.env), shows what is in it (never the token or the
#   secret) and calls the groups API once. Helps with "HTTP 401/403" from builder-sync.py:
#     aud without the admin API / scope kc-admin-api missing  -> 401 (client scope "kc-admin-api" as Default)
#     realm-management roles missing (view-users, query-groups) -> 403
#     403 with a Caddy server header                            -> /admin blocked by the proxy in front of Keycloak
# ============================================================================
set -uo pipefail
KIRA_DIR=/opt/kira
[ "$(id -u)" = 0 ] || { echo "Error: please run as root." >&2; exit 1; }
val() { [ -f "$1" ] && grep "^$2=" "$1" | tail -1 | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/'; }
CLIENT_ID=$(val "$KIRA_DIR/env/keycloak-sync.env" KC_SYNC_CLIENT_ID)
CLIENT_SECRET=$(val "$KIRA_DIR/env/keycloak-sync.env" KC_SYNC_CLIENT_SECRET)
KC_HOST=$(val "$KIRA_DIR/env/compose.env" KEYCLOAK_HOST)
KC_IP=$(val "$KIRA_DIR/env/compose.env" KEYCLOAK_IP)
ISS=$(val "$KIRA_DIR/env/librechat.env" OPENID_ISSUER)
[ -n "$CLIENT_SECRET" ] || { echo "Error: KC_SYNC_CLIENT_SECRET is empty in env/keycloak-sync.env." >&2; exit 1; }
[ -n "$ISS" ] || { echo "Error: OPENID_ISSUER is missing in env/librechat.env." >&2; exit 1; }
ROOT=${ISS%/realms/*}; REALM=${ISS##*/}
RES=()
[ -n "$KC_HOST" ] && [ -n "$KC_IP" ] && RES=(--resolve "$KC_HOST:443:$KC_IP")
echo "Issuer: $ISS   client: ${CLIENT_ID:-kira-sync}${KC_IP:+   (Keycloak via $KC_IP)}"

# client ID and secret go to curl on stdin (not visible in the process list)
TOKEN=$(curl -sS "${RES[@]}" "$ISS/protocol/openid-connect/token" -K - <<EOF | python3 -I -c 'import json, sys
try: print(json.load(sys.stdin).get("access_token", ""))
except ValueError: print("")'
data-urlencode = "grant_type=client_credentials"
data-urlencode = "client_id=${CLIENT_ID:-kira-sync}"
data-urlencode = "client_secret=$CLIENT_SECRET"
EOF
)
[ -n "$TOKEN" ] || { echo "No token – check the client ID/secret and \"Service accounts roles\" on the client."; exit 1; }

echo "== Token content =="
python3 -I - "$TOKEN" <<'PY'
import base64, json, sys, time
p = sys.argv[1].split(".")[1]; p += "=" * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
now = int(time.time())
for k in ("iss", "typ", "azp", "aud", "scope", "preferred_username"):
    print(f"  {k}: {c.get(k, '-')}")
print(f"  valid for: {c.get('exp', now) - now} s")
print(f"  realm-management roles: {c.get('resource_access', {}).get('realm-management', {}).get('roles', '-')}")
PY

echo "== Groups API =="
curl -s -i "${RES[@]}" "$ROOT/admin/realms/$REALM/groups?search=kira&max=1&briefRepresentation=true" -K - <<EOF \
  | sed -n '1p;/^[Ww][Ww][Ww]-[Aa]uthenticate/p;/^[Ss]erver/p;$p'
header = "Authorization: Bearer $TOKEN"
EOF
echo
echo "Expected: HTTP 200 and a JSON list. 401 = scope kc-admin-api missing, 403 = roles or proxy (see above)."
