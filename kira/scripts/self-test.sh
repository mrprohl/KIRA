#!/usr/bin/env bash
# ============================================================================
# self-test.sh – checks after starting that all services run and can reach each other.
#   /opt/kira/scripts/self-test.sh            containers + connections (costs no tokens)
#   /opt/kira/scripts/self-test.sh --request  additionally a real mini request to Claude via Bifrost
# On first start it waits until the containers are "healthy" (Onyx needs up to 15 minutes).
# Exit 0 = all ok, 1 = at least one error.
# ============================================================================
set -uo pipefail
KIRA_DIR=/opt/kira
setup_get() { sed -n "s/^$1=//p" "$KIRA_DIR/env/setup.env" | tail -1 | tr -d '"'; }
env_get()   { sed -n "s/^$2=//p" "$1" | tail -1 | sed 's/^"\(.*\)"$/\1/'; }

ONYX_ENABLED=$(setup_get ONYX_ENABLED)
DOMAIN=$(setup_get KIRA_DOMAIN)
LC_ENV=$KIRA_DIR/env/librechat.env
errors=0
ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [ERROR] %s\n' "$*"; errors=$((errors + 1)); }
hint() { printf '        -> %s\n' "$*"; }

CONTAINERS=(caddy bifrost bifrost-db librechat librechat-mongodb librechat-meilisearch librechat-rag librechat-vectordb
            searxng firecrawl firecrawl-playwright firecrawl-redis firecrawl-rabbitmq firecrawl-nuq-postgres)
TIMEOUT=420
if [ "$ONYX_ENABLED" = "true" ]; then
  CONTAINERS+=(onyx-api onyx-background onyx-web onyx-mcp onyx-inference-model onyx-indexing-model
               onyx-db onyx-opensearch onyx-cache onyx-nginx)
  TIMEOUT=1200
fi

state_of() {
  local s
  s=$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$1" 2>/dev/null) \
    || s="missing"
  printf '%s' "$s"
}

echo "== Containers (waiting up to $((TIMEOUT / 60)) minutes for \"healthy\") =="
start=$(date +%s)
progress=0
while :; do
  pending=0
  for c in "${CONTAINERS[@]}"; do
    # only wait for containers that are still starting – missing/exited/unhealthy ones are reported below
    case "$(state_of "$c")" in
      running/starting|created/*|restarting/*) pending=$((pending + 1)) ;;
    esac
  done
  [ "$pending" -eq 0 ] && break
  [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ] && break
  printf '\r  %2d containers not ready yet … (%3ss)' "$pending" "$(( $(date +%s) - start ))"
  progress=1
  sleep 10
done
[ "$progress" -eq 1 ] && printf '\r%60s\r' ''
for c in "${CONTAINERS[@]}"; do
  s=$(state_of "$c")
  case "$s" in
    running/healthy|running/no-healthcheck) ok "$c ($s)" ;;
    *) bad "$c ($s)"; hint "docker logs --tail 50 $c" ;;
  esac
done

# HTTP check from inside the LibreChat container (same networks and DNS as in operation)
lc_fetch() {   # lc_fetch <method> <URL> [bearer] [JSON body] – prints "status length" or "ERR message"
  docker exec -i librechat node -e '
    const [m, url, tok, body] = process.argv.slice(1);
    const h = {}; if (tok) h.Authorization = "Bearer " + tok; if (body) h["Content-Type"] = "application/json";
    fetch(url, { method: m, headers: h, body: body || undefined, signal: AbortSignal.timeout(60000) })
      .then(async r => { const t = await r.text(); console.log(r.status + " " + t.length + " " + t.slice(0, 160).replace(/\s+/g, " ")); })
      .catch(e => console.log("ERR " + (e.cause && e.cause.code ? e.cause.code : e.message)));
  ' "$1" "$2" "${3:-}" "${4:-}" 2>&1
}
check_http() {   # check_http <name> <expected regex> <hint> <method> <URL> [bearer] [body]
  local name=$1 expect=$2 tip=$3; shift 3
  local res; res=$(lc_fetch "$@")
  if [[ $res =~ $expect ]]; then ok "$name"; else bad "$name: ${res:0:200}"; hint "$tip"; fi
}

echo "== Connections =="
if [ "$(docker inspect -f '{{.State.Running}}' librechat 2>/dev/null)" != "true" ]; then
  bad "LibreChat is not running – connection tests skipped"; hint "docker logs --tail 80 librechat"
else
  VK=$(env_get "$LC_ENV" BIFROST_API_KEY)
  check_http "LibreChat -> Bifrost (models with vk-librechat)" '^200 ' \
    "docker logs --tail 50 bifrost; is VK_LIBRECHAT in /opt/bifrost/env/bifrost.env = BIFROST_API_KEY?" \
    GET http://bifrost:8080/v1/models "$VK"
  check_http "LibreChat -> RAG API (document search)" '^200 ' "docker logs --tail 50 librechat-rag" \
    GET http://rag_api:8000/health
  check_http "LibreChat -> SearXNG (search returns JSON)" '^200 [0-9]+ \{' \
    "docker logs --tail 50 searxng; 'json' under search.formats in /opt/websearch/searxng/settings.yml?" \
    GET "http://searxng:8080/search?q=wetter&format=json"
  check_http "LibreChat -> Firecrawl (reads example.com)" '^200 .*"success": ?true' \
    "docker logs --tail 80 firecrawl; needs internet (network websearch-outbound)" \
    POST http://firecrawl:3002/v2/scrape "$(env_get "$LC_ENV" FIRECRAWL_API_KEY)" '{"url":"https://example.com","formats":["markdown"]}'
  # branding: the files in the container must be those from /opt/kira/branding (else: restart missing)
  stale=""
  for f in favicon-32x32.png logo.svg; do
    [ "$(sha256sum < "$KIRA_DIR/branding/$f" 2>/dev/null)" = "$(docker exec librechat cat "/app/client/dist/assets/$f" 2>/dev/null | sha256sum)" ] \
      || stale="$stale $f"
  done
  if [ -z "$stale" ]; then ok "Branding (logo, favicon) active"
  else bad "Branding not active:$stale"; hint "docker restart librechat (after replacing files in /opt/kira/branding)"; fi
  ISSUER=$(env_get "$LC_ENV" OPENID_ISSUER)
  check_http "LibreChat -> Keycloak ($ISSUER)" '^200 ' \
    "KEYCLOAK_INTERNAL_IP in env/setup.env, LAN block exception (config/egress.env), firewall of the Keycloak server (443 from this host)" \
    GET "$ISSUER/.well-known/openid-configuration"
  if [ "$ONYX_ENABLED" = "true" ]; then
    check_http "LibreChat -> Onyx (nginx)" '^200 ' "docker logs --tail 50 onyx-nginx" GET http://onyx-nginx/nginx-health
    res=$(lc_fetch GET http://onyx-mcp:8090/)
    if [[ $res == ERR* ]]; then bad "LibreChat -> Onyx MCP: $res"; hint "docker logs --tail 50 onyx-mcp"
    else ok "LibreChat -> Onyx MCP reachable"; fi
    [ -n "$(env_get "$LC_ENV" ONYX_API_KEY)" ] || printf '  [info] ONYX_API_KEY is still missing – agent "Intranet" is hidden (README, section Onyx)\n'
  fi
  if [ "${1:-}" = "--request" ]; then
    check_http "Bifrost -> Anthropic (mini request claude-haiku-5-5)" '^200 ' \
      "docker logs --tail 50 bifrost – provider key, budget (402) or model not allowed" \
      POST http://bifrost:8080/v1/chat/completions "$VK" \
      '{"model":"anthropic/claude-haiku-5-5","max_tokens":5,"messages":[{"role":"user","content":"Just say: ok"}]}'
  fi
  if [ "$(setup_get CODE_INTERPRETER)" = "true" ]; then
    echo "== Code interpreter =="
    for c in codeapi codeapi-worker codeapi-sandbox codeapi-egress codeapi-files codeapi-toolcall codeapi-redis codeapi-minio; do
      st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo missing)
      case $st in running|running/healthy) ;; *) bad "container $c: $st"
        hint "bash /opt/codeinterpreter/codeapi.sh ps; bash /opt/codeinterpreter/codeapi.sh logs --tail 50 ${c#codeapi-}" ;; esac
    done
    check_http "LibreChat -> code interpreter API" '^200 ' \
      "bash /opt/codeinterpreter/codeapi.sh ps – network kira-code, container codeapi" GET http://codeapi:3112/v1/health
    # end to end like LibreChat: signed token (Ed25519), Python in the KVM sandbox, a Word file in /mnt/data
    res=$(docker exec -i librechat node - 2>&1 <<'JS'
const c = require('crypto');
const e = process.env, now = Math.floor(Date.now() / 1000);
const b64 = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url');
const sub = 'kira-self-test', tenant = e.CODEAPI_JWT_SINGLE_TENANT_ID || 'kira', role = 'USER', ps = 'librechat_jwt';
const hash = c.createHash('sha256').update(JSON.stringify({ chc_user_id: '', org_id: '', principal_source: ps, role,
  service_id: '', sub, tenant_id: tenant })).digest('hex');
const input = b64({ alg: 'EdDSA', typ: 'JWT', kid: e.CODEAPI_JWT_KID }) + '.' + b64({ iss: e.CODEAPI_JWT_ISSUER,
  aud: e.CODEAPI_JWT_AUDIENCE, sub, iat: now, nbf: now, exp: now + 60, jti: c.randomUUID(), tenant_id: tenant, role,
  principal_source: ps, auth_context_hash: hash });
const key = c.createPrivateKey(Buffer.from(e.CODEAPI_JWT_PRIVATE_KEY_BASE64, 'base64').toString());
const jwt = input + '.' + c.sign(null, Buffer.from(input), key).toString('base64url');
const code = "from docx import Document\nd = Document(); d.add_heading('KIRA Selbsttest', 1)\n" +
  "d.save('/mnt/data/selbsttest.docx'); print('KIRA-' + 'OK')";
fetch(e.LIBRECHAT_CODE_BASEURL + '/exec', { method: 'POST', signal: AbortSignal.timeout(120000),
  headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + jwt },
  body: JSON.stringify({ lang: 'py', code }) })
  .then(async (r) => console.log(r.status, (await r.text()).replace(/\s+/g, ' ').slice(0, 2000)))
  .catch((err) => console.log('ERR', err.message));
JS
)
    if [[ $res == "200 "* && $res == *KIRA-OK* && $res == *selbsttest.docx* ]]; then ok "code run in the sandbox: Python and a Word file work"
    else bad "code run in the sandbox: ${res:0:300}"
      hint "401: key pair (setup.sh) – 5xx: bash /opt/codeinterpreter/codeapi.sh logs --tail 80 service-worker sandbox-runner (/dev/kvm?)"; fi
  fi
  if [ "$(setup_get PRIVACY_GUARD)" = "true" ]; then
    echo "== Privacy guard =="
    mode=$(setup_get GUARD_MODE); mode=${mode:-observe}
    if docker logs bifrost 2>&1 | grep -q "privacy-guard: active, mode=$mode"; then ok "plugin loaded (mode $mode)"
    else bad "plugin not loaded or old mode"; hint "docker logs bifrost 2>&1 | grep -i -E 'plugin|privacy-guard' – image BIFROST_IMAGE in /opt/bifrost/env/versions.env, then docker restart bifrost"; fi
    for pair in GUARD_PRIVACY_URL:kira-privacy GUARD_SAFETY_URL:kira-safety GUARD_EMBEDDING_URL:kira-embedding GUARD_ANSWER_URL:kira-answer; do
      url=$(setup_get "${pair%%:*}"); model=${pair##*:}; url=${url%/}
      # from inside Bifrost (same network and firewall as in operation); the key is in its environment
      res=$(docker exec bifrost sh -c 'wget -q -T 10 -O - --header "Authorization: Bearer $VLLM_API_KEY" "$0/v1/models"' "$url" 2>&1)
      if [[ $res == *"\"$model\""* ]]; then ok "Bifrost -> vLLM $model ($url)"
      else bad "Bifrost -> vLLM $model ($url): ${res:0:150}"
        hint "vLLM on that server running with --served-model-name $model and the same --api-key? Firewall: BIFROST_LAN_DST in config/egress.env"; fi
    done
    check_http "LibreChat -> Bifrost -> local embeddings (kira-embedding)" '^200 ' \
      "docker logs --tail 50 bifrost; vLLM of kira-embedding started with --task embed?" \
      POST http://bifrost:8080/v1/embeddings "$VK" '{"model":"vllm/kira-embedding","input":"Selbsttest"}'
    if [ "${1:-}" = "--request" ]; then
      # a test IBAN (from the documentation of the German banks) must be recognised: local (enforce) or counted (observe)
      lc_fetch POST http://bifrost:8080/v1/chat/completions "$VK" \
        '{"model":"anthropic/claude-haiku-5-5","max_tokens":10,"messages":[{"role":"user","content":"KIRA-Selbsttest: DE89 3704 0044 0532 0130 00 – antworte nur mit OK."}]}' >/dev/null
      sleep 3
      if docker logs --since 2m bifrost 2>&1 | grep -q 'privacy-guard mode=[a-z]* decision=local endpoint=chat categories=[a-z_,-]*iban'; then
        ok "test request with an IBAN recognised (decision local)"
      else bad "test request with an IBAN not recognised"; hint "docker logs --since 5m bifrost 2>&1 | grep privacy-guard"; fi
    fi
  fi
fi

echo "== Caddy =="
res=$(curl -sk -m 15 -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/health" 2>&1 || true)
if [ "$res" = "200" ]; then ok "https://$DOMAIN/health via Caddy (local)"
else bad "https://$DOMAIN/health via Caddy: HTTP $res"; hint "docker logs --tail 50 caddy"; fi
if docker logs caddy 2>&1 | grep "certificate obtained successfully" >/dev/null; then ok "Let's Encrypt certificate obtained"
else printf '  [info] no new certificate in the log yet – check DNS and port 80 (docker logs caddy | grep -i acme)\n'; fi

if [ "$(setup_get LAN_BLOCK)" = "true" ]; then
  echo "== LAN block =="
  if "$KIRA_DIR/scripts/egress-firewall.sh" status -q >/dev/null 2>&1; then ok "rules active"
  else bad "rules missing"; hint "systemctl restart kira-egress-firewall; journalctl -u kira-egress-firewall"; fi
  if grep -q '^LIBRECHAT_ONLY_DST="[0-9]' "$KIRA_DIR/config/egress.env" 2>/dev/null \
     && [ "$(docker inspect -f '{{.State.Running}}' librechat 2>/dev/null)" = "true" ]; then
    # plain TCP connect to a public address (no TLS/DNS involved): must time out
    res=$(docker exec librechat node -e 'const s=require("net").connect(443,"1.1.1.1");s.setTimeout(5000);s.on("connect",()=>{console.log("open");s.destroy()});s.on("timeout",()=>{console.log("blocked");s.destroy()});s.on("error",(e)=>console.log("blocked ("+e.code+")"))' 2>&1)
    if [[ $res == blocked* ]]; then ok "LibreChat without internet (only Keycloak)"
    else bad "LibreChat reaches the internet: $res"; hint "systemctl restart kira-egress-firewall; config/egress.env"; fi
  fi
fi

echo
if [ "$errors" -eq 0 ]; then echo "Self-test: all OK."; exit 0; fi
echo "Self-test: $errors error(s)."; exit 1
