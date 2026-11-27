#!/usr/bin/env bash
# ============================================================================
# KIRA – central setup for all stacks under /opt:
#   caddy (reverse proxy) · bifrost (LLM gateway) · kira (LibreChat) · websearch (SearXNG, Firecrawl) · onyx (optional)
#   · codeinterpreter (optional, needs /dev/kvm)
#
#   Usage:  bash /opt/kira/setup.sh
#
# Switches and answers are stored in /opt/kira/env/setup.env. Running it again is safe:
#   - Secrets (env/*.env) are generated once and never overwritten.
#   - Derived files (librechat.yaml, Caddyfile, compose.env, egress.env) are regenerated on every run.
#   - To change a switch: edit the value in env/setup.env (true/false), then run setup.sh again.
# ============================================================================
set -Eeuo pipefail
trap 'echo "Error: setup.sh line $LINENO – command: $BASH_COMMAND" >&2' ERR

KIRA=/opt/kira
CADDY=/opt/caddy
BIFROST=/opt/bifrost
WEBSEARCH=/opt/websearch
ONYX=/opt/onyx
CODEI=/opt/codeinterpreter
STACK_DIRS=("$CADDY" "$BIFROST" "$KIRA" "$WEBSEARCH" "$ONYX" "$CODEI")
SETUP_ENV=$KIRA/env/setup.env
EMBEDDING_MODEL=text-embedding-3-small      # OpenAI embedding model for document search (via Bifrost)

# ---------------------------------------------------------------- Helpers
info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }

random_hex() { openssl rand -hex "${1:-32}"; }

# Answers must not contain characters that cause trouble in env files
SAFE_RE='^[][A-Za-z0-9 ._:/@,+=?&%~-]*$'

ask() {   # ask <variable> <prompt> [secret] – required, no default
  local __var=$1 __prompt=$2 __secret=${3:-} __val=""
  while [ -z "$__val" ]; do
    if [ -n "$__secret" ]; then read -rsp "$__prompt: " __val; echo; else read -rp "$__prompt: " __val; fi
    __val=$(printf '%s' "$__val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ -n "$__val" ] && ! [[ $__val =~ $SAFE_RE ]]; then
      echo "  Please do not use quotes, \$, \\ or backticks." >&2; __val=""
    fi
  done
  printf -v "$__var" '%s' "$__val"
}

ask_optional() {   # ask_optional <variable> <prompt> [secret] – empty input allowed
  local __var=$1 __prompt=$2 __secret=${3:-} __val=""
  while :; do
    if [ -n "$__secret" ]; then read -rsp "$__prompt: " __val; echo; else read -rp "$__prompt: " __val; fi
    __val=$(printf '%s' "$__val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ $__val =~ $SAFE_RE ]] && break
    echo "  Please do not use quotes, \$, \\ or backticks." >&2
  done
  printf -v "$__var" '%s' "$__val"
}

ask_yesno() {   # ask_yesno <variable> <prompt> – sets true/false
  local __var=$1 __prompt=$2 __val=""
  while :; do
    read -rp "$__prompt (yes/no): " __val
    case "${__val,,}" in
      y|yes|j|ja) printf -v "$__var" 'true'; return ;;
      n|no|nein)  printf -v "$__var" 'false'; return ;;
    esac
  done
}

ask_number() {   # ask_number <variable> <prompt>
  local __v=""
  while :; do
    ask __v "$2"
    __v=${__v/,/.}
    [[ $__v =~ ^[0-9]+([.][0-9]+)?$ ]] && break
    echo "  Please enter a number (e.g. 25 or 7.5)." >&2
  done
  printf -v "$1" '%s' "$__v"
}

env_get() {   # env_get <file> <variable> – value without surrounding quotes
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -1 | sed 's/^"\(.*\)"$/\1/'
}

env_set() {   # env_set <file> <variable> <value> – replaces or appends KEY="value", keeps permissions
  local file=$1 key=$2 value=$3 tmp
  tmp=$(mktemp "$file.XXXXXX")
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { if (!done) { print k "=\"" v "\""; done = 1 }; next }
    { print }
    END { if (!done) print k "=\"" v "\"" }' "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

setup_has() { grep -q "^$1=" "$SETUP_ENV" 2>/dev/null; }
setup_get() { env_get "$SETUP_ENV" "$1"; }
setup_set() { env_set "$SETUP_ENV" "$1" "$2"; }
is_true() { [ "$(setup_get "$1")" = "true" ]; }

ensure_text() {     # ensure_text <KEY> <prompt> [regex] [hint]
  local key=$1 prompt=$2 re=${3:-} hint=${4:-} val
  setup_has "$key" && [ -n "$(setup_get "$key")" ] && return 0
  while :; do
    ask val "$prompt"
    { [ -z "$re" ] || [[ $val =~ $re ]]; } && break
    echo "  Invalid input.${hint:+ $hint}" >&2
  done
  setup_set "$key" "$val"
}

ensure_optional() { # ensure_optional <KEY> <prompt> [regex] [hint]
  local key=$1 prompt=$2 re=${3:-} hint=${4:-} val
  setup_has "$key" && return 0
  while :; do
    ask_optional val "$prompt"
    { [ -z "$val" ] || [ -z "$re" ] || [[ $val =~ $re ]]; } && break
    echo "  Invalid input.${hint:+ $hint}" >&2
  done
  setup_set "$key" "$val"
}

ensure_yesno() {    # ensure_yesno <KEY> <prompt>
  local key=$1 prompt=$2 val
  if setup_has "$key"; then
    case "$(setup_get "$key")" in true|false) return 0 ;; esac
    warn "$SETUP_ENV: $key must be true or false – asking again."
  fi
  ask_yesno val "$prompt"
  setup_set "$key" "$val"
}

login_duration_ms() {   # login_duration_ms <8h…365d> – milliseconds, exit 1 if invalid
  local v=${1,,} n
  if [[ $v =~ ^([0-9]+)h$ ]]; then n=$((10#${BASH_REMATCH[1]} * 3600))
  elif [[ $v =~ ^([0-9]+)d$ ]]; then n=$((10#${BASH_REMATCH[1]} * 86400))
  else return 1; fi
  [ "$n" -ge $((8 * 3600)) ] && [ "$n" -le $((365 * 86400)) ] || return 1
  echo $((n * 1000))
}

duration_hours() {      # duration_hours <Nh|Nd> <min_h> <max_h> – hours, exit 1 if invalid
  local v=${1,,} n
  if [[ $v =~ ^([0-9]+)h$ ]]; then n=$((10#${BASH_REMATCH[1]}))
  elif [[ $v =~ ^([0-9]+)d$ ]]; then n=$((10#${BASH_REMATCH[1]} * 24))
  else return 1; fi
  [ "$n" -ge "$2" ] && [ "$n" -le "$3" ] || return 1
  echo "$n"
}

ensure_duration() {     # ensure_duration <KEY> <prompt> <min_h> <max_h> <hint> – empty allowed (= default)
  local key=$1 prompt=$2 min=$3 max=$4 hint=$5 val
  if setup_has "$key"; then
    val=$(setup_get "$key")
    { [ -z "$val" ] || duration_hours "$val" "$min" "$max" >/dev/null; } && return 0
    warn "$SETUP_ENV: $key=$val is invalid – asking again."
  fi
  while :; do
    ask_optional val "$prompt"
    { [ -z "$val" ] || duration_hours "$val" "$min" "$max" >/dev/null; } && break
    echo "  $hint" >&2
  done
  setup_set "$key" "${val,,}"
}

days_of() {             # days_of <Nd> <min_d> <max_d> – days, exit 1 if invalid (whole days only, e.g. 90d)
  local v=${1,,} n
  [[ $v =~ ^([0-9]{1,5})d$ ]] || return 1
  n=$((10#${BASH_REMATCH[1]}))
  [ "$n" -ge "$2" ] && [ "$n" -le "$3" ] || return 1
  echo "$n"
}

ensure_days() {         # ensure_days <KEY> <prompt> <min_d> <max_d> – empty allowed (= default)
  local key=$1 prompt=$2 min=$3 max=$4 val
  if setup_has "$key"; then
    val=$(setup_get "$key")
    { [ -z "$val" ] || days_of "$val" "$min" "$max" >/dev/null; } && return 0
    warn "$SETUP_ENV: $key=$val is invalid – asking again."
  fi
  while :; do
    ask_optional val "$prompt"
    { [ -z "$val" ] || days_of "$val" "$min" "$max" >/dev/null; } && break
    echo "  Please enter days from ${min}d to ${max}d, e.g. 90d." >&2
  done
  setup_set "$key" "${val,,}"
}

ensure_number() {       # ensure_number <KEY> <prompt> <min> <max> – empty allowed (= default)
  local key=$1 prompt=$2 min=$3 max=$4 val
  if setup_has "$key"; then
    val=$(setup_get "$key")
    { [ -z "$val" ] || { [[ $val =~ ^[0-9]{1,7}$ ]] && [ "$((10#$val))" -ge "$min" ] && [ "$((10#$val))" -le "$max" ]; }; } && return 0
    warn "$SETUP_ENV: $key=$val is invalid – asking again."
  fi
  while :; do
    ask_optional val "$prompt"
    if [ -z "$val" ]; then break; fi
    if [[ $val =~ ^[0-9]{1,7}$ ]] && [ "$((10#$val))" -ge "$min" ] && [ "$((10#$val))" -le "$max" ]; then
      val=$((10#$val)); break
    fi
    echo "  Please enter a number from $min to $max." >&2
  done
  setup_set "$key" "$val"
}

file_hash() { { cat "$@" 2>/dev/null || true; } | sha256sum | cut -d" " -f1; }

DOMAIN_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
IPLIST_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?( +([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?)*$'
MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
VLLM_URL_RE='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$'
URL_RE='^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]"$`\\]*)?$'

is_private_ip() {
  case "$1" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------- 0. Prerequisites
section "Checking prerequisites"
[ "$(id -u)" = 0 ] || die "please run as root (sudo bash $KIRA/setup.sh)."
[ -t 0 ] || die "setup.sh asks questions and needs a terminal."
for c in docker openssl python3 curl awk sed sha256sum; do
  command -v "$c" >/dev/null || die "program '$c' is missing (e.g. apt install $c)."
done
for d in "${STACK_DIRS[@]}"; do
  [ -d "$d" ] || die "$d is missing – extract the package with 'unzip -o kira-stack.zip -d /opt'."
done
[ "$(cd "$(dirname "$0")" && pwd)" = "$KIRA" ] || die "setup.sh must be located in $KIRA (paths in the compose files are fixed)."
docker info >/dev/null 2>&1 || die "Docker is not running (systemctl status docker)."
compose_version=$(docker compose version --short 2>/dev/null | sed 's/^v//') || die "Docker Compose (plugin) is missing."
if ! printf '%s\n%s\n' "2.20.0" "$compose_version" | sort -V -C; then
  die "Docker Compose $compose_version is too old – at least 2.20 is required (include with env_file)."
fi
info "Docker $(docker version -f '{{.Server.Version}}'), Compose $compose_version – ok."

# Files from Windows: strip line endings (CRLF), set permissions for Linux/Docker
# (not in codeinterpreter/src – the cloned sources keep their own line endings and permissions)
for d in "${STACK_DIRS[@]}"; do
  find "$d" -path "$CODEI/src" -prune -o -type f \( -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.yml' -o -name '*.yaml' -o -name '*.env' \
       -o -name '*.example' -o -name '*.md' -o -name '*.json' -o -name '*.caddy' -o -name '*.off' -o -name 'Caddyfile' \
       -o -name '*.template' -o -name '*.conf' \) -exec sed -i 's/\r$//' {} +
  # skip env/ (secrets) – stays 700/600
  find "$d" \( -path "$d/env" -o -path "$CODEI/src" \) -prune -o -type d -exec chmod 755 {} +
  find "$d" \( -path "$d/env" -o -path "$CODEI/src" \) -prune -o -type f -exec chmod 644 {} +
  if [ -d "$d/env" ]; then chmod 700 "$d/env"; find "$d/env" -type f -exec chmod 600 {} +; fi
done
chmod 755 "$KIRA/setup.sh" "$KIRA"/scripts/*.sh "$KIRA"/scripts/*.py "$BIFROST"/db/init/*.sh "$ONYX"/nginx/run-nginx.sh \
  "$CODEI/codeapi.sh"
info "Line endings and file permissions normalised."

umask 077
for d in "${STACK_DIRS[@]}"; do mkdir -p "$d/env"; chmod 700 "$d/env"; done
touch "$SETUP_ENV"; chmod 600 "$SETUP_ENV"
[ -s "$SETUP_ENV" ] || printf '# KIRA – switches and answers from setup.sh. To change: edit the value, then run bash %s/setup.sh\n' "$KIRA" > "$SETUP_ENV"
# switches of an earlier test version (office download links, external code server) – replaced by the local code interpreter
sed -i '/^OFFICE_DOCUMENTS=/d; /^OFFICE_LINK_HOURS=/d; /^CODE_API_URL=/d' "$SETUP_ENV"

# ---------------------------------------------------------------- 1. Switches and basic settings
section "Basic settings (stored in env/setup.env)"
ensure_text KIRA_DOMAIN "Domain for KIRA (e.g. kira.example.com)" "$DOMAIN_RE" "Host name only, without https://."
ensure_text ACME_EMAIL "E-mail address for Let's Encrypt (certificate expiry notices, e.g. kira@example.com)" '^[^@ ]+@[^@ ]+\.[^@ ]+$'
ensure_optional UPSTREAM_PROXY_IP "IP of an upstream reverse proxy that forwards 80/443 to this host (empty = none)" "$IPV4_RE"
ensure_optional KEYCLOAK_INTERNAL_IP "Internal IP of the Keycloak server, if KIRA should reach it directly in the LAN (empty = normal DNS)" "$IPV4_RE"

section "Features"
ensure_yesno ONYX_ENABLED "Set up Onyx (intranet search, needs about 12–16 GB of additional RAM)?"
if is_true ONYX_ENABLED; then
  ensure_text ONYX_DOMAIN "Domain for the Onyx web interface (admin area, e.g. onyx.example.com)" "$DOMAIN_RE"
  # Onyx has its own accounts with open sign-up (the first account becomes admin) – only admins may reach it
  ensure_text ONYX_ALLOWED_IPS "Allowed IPs for the Onyx web interface (admins only, space-separated)" "$IPLIST_RE"
fi
ensure_yesno IMAGE_GENERATION "Enable image generation (image agent, agents/40-images.env)?"
if is_true IMAGE_GENERATION; then
  ensure_text IMAGE_MODEL "OpenAI image model in Bifrost, without \"openai/\" (e.g. gpt-image-2)" "$MODEL_RE"
fi
if ! setup_has CODE_INTERPRETER && [ ! -c /dev/kvm ]; then
  info "Note: this server has no /dev/kvm (hardware virtualisation) – the code interpreter cannot run here (answer no)."
fi
ensure_yesno CODE_INTERPRETER "Code interpreter: KIRA runs Python in a sandbox – analyses, charts and documents (Word, Excel, PowerPoint, PDF) directly in the chat; needs /dev/kvm (codeinterpreter/README.md)?"
if is_true CODE_INTERPRETER; then
  ensure_number CODE_PARALLEL "How many code runs at the same time? (1 to 16; empty = 4, each needs up to 2 GB RAM)" 1 16
fi
ensure_yesno SPEECH "Enable speech input and speech output?"
if is_true SPEECH; then
  ensure_text STT_MODEL "OpenAI model for speech input, without \"openai/\" (e.g. gpt-transcribe)" "$MODEL_RE"
  ensure_optional TTS_MODEL "OpenAI model for speech output, without \"openai/\" (e.g. gpt-4o-mini-tts; empty = no speech output)" "$MODEL_RE"
  if [ -n "$(setup_get TTS_MODEL)" ]; then
    ensure_optional TTS_VOICE "Default voice for all users (alloy, ash, coral, echo, fable, nova, onyx, sage, shimmer; empty = fable)" \
      '^(alloy|ash|coral|echo|fable|nova|onyx|sage|shimmer)$' "Allowed: alloy, ash, coral, echo, fable, nova, onyx, sage, shimmer."
  fi
fi

ensure_yesno PRIVACY_GUARD "Privacy guard: check every request with own LLMs (vLLM) – personal or secret data is answered locally, harmful requests are refused? (kira/PRIVACY-GUARD.md)"
if is_true PRIVACY_GUARD; then
  info "Privacy guard: addresses of the vLLM servers (one model each, served under the names kira-privacy, kira-safety,"
  info "kira-embedding, kira-answer – vllm/README.md). Form http://IP:port; Bifrost may reach exactly these."
  ensure_text GUARD_PRIVACY_URL "vLLM address of the privacy checker (e.g. http://10.0.0.50:8101)" "$VLLM_URL_RE" "Form http://host:port."
  ensure_text GUARD_SAFETY_URL "vLLM address of the safety checker, Qwen3Guard (e.g. http://10.0.0.51:8102)" "$VLLM_URL_RE" "Form http://host:port."
  ensure_text GUARD_EMBEDDING_URL "vLLM address of the embedding model (e.g. http://10.0.0.52:8103)" "$VLLM_URL_RE" "Form http://host:port."
  ensure_text GUARD_ANSWER_URL "vLLM address of the local answer model (e.g. http://10.0.0.53:8104)" "$VLLM_URL_RE" "Form http://host:port."
  ensure_optional GUARD_MODE "Mode: observe (only decide and count – start with this) or enforce (empty = observe)" '^(observe|enforce)$' "observe or enforce."
  ensure_yesno GUARD_SLACK "Privacy guard: weekly counts (no content) to Slack?"
fi

ensure_yesno AGENT_GROUPS "Restrict agents per Keycloak group? (mapping in agents/groups.env, needs the \"groups\" claim in Keycloak)"

section "Login"
if ! setup_has LOGIN_DURATION || [ -z "$(setup_get LOGIN_DURATION)" ]; then
  while :; do
    ask_optional val "How long does a login stay active? (8h to 365d, e.g. 12h or 90d; empty = 30d)"
    val=${val:-30d}
    login_ms=$(login_duration_ms "$val") && break
    echo "  Please enter a duration between 8h and 365d (number followed by h or d)." >&2
  done
  setup_set LOGIN_DURATION "$val"
fi
login_ms=$(login_duration_ms "$(setup_get LOGIN_DURATION)") \
  || die "LOGIN_DURATION=$(setup_get LOGIN_DURATION) in $SETUP_ENV is invalid – 8h to 365d (e.g. 30d)."

section "Usage and privacy"
ensure_number MESSAGE_LIMIT "How many messages may a user send per minute? (empty = 20, 0 = no limit)" 0 1000
ensure_yesno TERMS_ENABLED "Require users to accept the terms of use at first login? (text: $KIRA/config/terms-of-use.md)"
ensure_optional PRIVACY_URL "Link to the privacy policy (e.g. https://intranet.example.com/privacy-kira; empty = none)" "$URL_RE" "Full address including https://."
ensure_optional HELP_URL "Link to the help page in the user menu (guide, contacts; empty = no menu entry)" "$URL_RE" "Full address including https://."
ensure_duration CHAT_RETENTION "Delete chats automatically after … (1d to 365d, counted from the start of the chat; empty = never)" 24 8760 \
  "Please enter a duration between 1d and 365d (e.g. 90d) or leave empty."
ensure_duration TEMP_CHAT_RETENTION "Delete temporary chats after … (1h to 365d; empty = 24h)" 1 8760 \
  "Please enter a duration between 1h and 365d (e.g. 24h)."
ensure_yesno CONTEXT_USAGE "Show the \"context window\" panel (token usage, \"compress context\" button) to all users?"
while :; do
  ensure_number COMPACT_AT "Summarise long chats automatically from how many tokens? (20000 to 1000000; empty = 100000, 0 = only at the model limit)" 0 1000000
  v=$(setup_get COMPACT_AT)
  if [ -z "$v" ] || [ "$v" = 0 ] || [ "$v" -ge 20000 ]; then break; fi
  echo "  Please enter 0 or a value of at least 20000 (lower values summarise too often)." >&2
  sed -i '/^COMPACT_AT=/d' "$SETUP_ENV"
done
ensure_days BIFROST_LOG_RETENTION "Keep Bifrost logs (requests, costs) for … (1d to 3650d; empty = 90d)" 1 3650

section "File uploads"
ensure_number UPLOAD_MAX_MB "Largest allowed file in MB (1 to 50; empty = 20)" 1 50
ensure_number UPLOAD_MAX_FILES "Maximum number of files per message? (1 to 50; empty = 10)" 1 50
ensure_yesno UPLOAD_OFFICE_ONLY "Allow office file types only (PDF, Office, OpenDocument, text/CSV, images)?"

section "Logging in Bifrost"
ensure_yesno SEND_USER_HEADERS "Should user data (e-mail, name) be visible in Bifrost? (Note: only with the users' knowledge)"
ensure_yesno LOG_CHAT_CONTENT "Should chat content (questions and answers) be logged in Bifrost? (Note: only with the users' knowledge)"

section "Network and access"
ensure_yesno LAN_BLOCK "Set up the LAN block? (containers with internet access can reach neither the LAN nor the host – recommended)"
ensure_optional LLM_API_DOMAIN "Domain for the LLM API (OpenAI-compatible access for external applications, e.g. llm.example.com; empty = none)" "$DOMAIN_RE"
if [ -n "$(setup_get LLM_API_DOMAIN)" ]; then
  ensure_text LLM_API_ALLOWED_IPS "Allowed IPs for the LLM API (space-separated)" "$IPLIST_RE"
fi
ensure_optional BIFROST_UI_DOMAIN "Domain for the Bifrost web interface (empty = SSH tunnel only)" "$DOMAIN_RE"
if [ -n "$(setup_get BIFROST_UI_DOMAIN)" ]; then
  ensure_text BIFROST_UI_ALLOWED_IPS "Allowed IPs for the Bifrost web interface (space-separated)" "$IPLIST_RE"
fi
setup_has AGENT_BUILDER || setup_set AGENT_BUILDER false

if is_true CODE_INTERPRETER; then
  [ -c /dev/kvm ] || die "CODE_INTERPRETER=true needs /dev/kvm – this server has no hardware virtualisation (in a VM: enable
  nested virtualisation, CPU type \"host\"). Or set CODE_INTERPRETER=false in $SETUP_ENV and run setup.sh again."
  command -v git >/dev/null || die "program 'git' is missing (apt install git) – needed for the code interpreter."
  printf '%s\n%s\n' "2.24.0" "$compose_version" | sort -V -C \
    || die "Docker Compose $compose_version is too old for the code interpreter – at least 2.24 is required."
fi

DOMAIN=$(setup_get KIRA_DOMAIN)
UPSTREAM_IP=$(setup_get UPSTREAM_PROXY_IP)
KC_IP=$(setup_get KEYCLOAK_INTERNAL_IP)

# ---------------------------------------------------------------- 2. Versions
section "Versions"
for d in "${STACK_DIRS[@]}"; do
  if [ -f "$d/env/versions.env" ]; then
    info "$d/env/versions.env exists – unchanged."
  else
    cp "$d/versions.env.example" "$d/env/versions.env"; info "$d/env/versions.env created (template)."
  fi
done

# ---------------------------------------------------------------- 3. Bifrost: keys and configuration
section "Bifrost (LLM gateway)"
if [ -f "$BIFROST/env/bifrost.env" ]; then
  info "bifrost/env/bifrost.env exists – unchanged."
else
  ask ANTHROPIC "Anthropic API key (sk-ant-api…/sk-ant-usr…, scoped to one workspace)" secret
  ask OPENAI    "OpenAI API key (sk-proj-…, platform.openai.com)" secret
  case $ANTHROPIC in
    sk-ant-oat*) warn "This is a subscription/OAuth token (sk-ant-oat…) – it does not work for the API." ;;
    sk-ant-admin*) warn "This is an Admin API key (sk-ant-admin…) – it cannot send requests to Claude." ;;
    sk-ant-*) ;;
    *) warn "Key does not start with sk-ant- – please check." ;;
  esac
  # External services (e.g. automation tools, own scripts): one virtual key per service via the LLM API
  info "External services that should use Bifrost via the LLM API – one virtual key per service."
  info "If a service should keep its current key (sk-bf-…), enter it – otherwise a new one is generated."
  EXT_LINES=""; EXT_SEEN=" librechat onyx "
  while :; do
    ask_optional EXT_NAME "Name of the external service (e.g. automation; empty = done)"
    [ -z "$EXT_NAME" ] && break
    EXT_NAME=$(printf '%s' "${EXT_NAME,,}" | tr ' _' '--')
    if ! [[ $EXT_NAME =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]; then
      echo "  Only letters a-z, digits and hyphens (max. 31 characters)." >&2; continue
    fi
    if [[ $EXT_SEEN == *" $EXT_NAME "* ]]; then
      echo "  The name $EXT_NAME is already taken." >&2; continue
    fi
    while :; do
      ask_optional EXT_VK "Existing virtual key for $EXT_NAME (sk-bf-…, empty = generate a new one)" secret
      if [ -n "$EXT_VK" ] && [[ $EXT_VK != sk-bf-* ]]; then
        echo "  Virtual keys must start with sk-bf-." >&2; continue
      fi
      # Bifrost rejects the same key for two services ("a record with this hash already exists")
      if [ -n "$EXT_VK" ] && [[ $'\n'$EXT_LINES == *"=$EXT_VK"$'\n'* ]]; then
        echo "  This key is already assigned to another service – each service needs its own." >&2; continue
      fi
      break
    done
    EXT_ENV="VK_EXT_$(printf '%s' "$EXT_NAME" | tr 'a-z-' 'A-Z_')"
    if [ -n "$EXT_VK" ]; then how="existing key"; else how="new key"; EXT_VK="sk-bf-$(random_hex 24)"; fi
    EXT_LINES="$EXT_LINES$EXT_ENV=$EXT_VK"$'\n'
    EXT_SEEN="$EXT_SEEN$EXT_NAME "
    info "  $EXT_NAME added ($how)."
  done
  DB_PW=$(random_hex)
  cat > "$BIFROST/env/database.env" <<EOF
# PostgreSQL for Bifrost – generated by setup.sh. Passwords only take effect on first start (empty volume).
POSTGRES_PASSWORD=$(random_hex)
BIFROST_DB_PASSWORD=$DB_PW
EOF
  cat > "$BIFROST/env/bifrost.env" <<EOF
# Bifrost – generated by setup.sh. Never change BIFROST_ENCRYPTION_KEY (encrypts keys in the database).
ANTHROPIC_API_KEY=$ANTHROPIC
OPENAI_API_KEY=$OPENAI
BIFROST_ENCRYPTION_KEY=$(random_hex)
BIFROST_ADMIN_USER=admin
BIFROST_ADMIN_PASSWORD=$(random_hex 16)
BIFROST_DB_PASSWORD=$DB_PW
# Virtual keys per service (prefix sk-bf- is required for "Authorization: Bearer")
VK_LIBRECHAT=sk-bf-$(random_hex 24)
VK_ONYX=sk-bf-$(random_hex 24)
# External services via the LLM API (one VK_EXT_<NAME> per service; more: add a line and register it in bifrost.json)
EOF
  printf '%s' "$EXT_LINES" >> "$BIFROST/env/bifrost.env"
  unset ANTHROPIC OPENAI EXT_VK EXT_LINES
  info "bifrost/env/bifrost.env and database.env created."
fi
VK_LIBRECHAT=$(env_get "$BIFROST/env/bifrost.env" VK_LIBRECHAT)
[ -n "$VK_LIBRECHAT" ] || die "VK_LIBRECHAT is missing in $BIFROST/env/bifrost.env."
if is_true PRIVACY_GUARD && [ -z "$(env_get "$BIFROST/env/bifrost.env" VLLM_API_KEY)" ]; then
  info "Privacy guard: API key of the vLLM servers (vllm serve … --api-key <key>, the same on all of them)."
  ask_optional VLLM_KEY "vLLM API key (empty = generate one now)" secret
  if [ -z "$VLLM_KEY" ]; then
    VLLM_KEY=$(random_hex 24)
    info "New key generated – put it into the env files of the vLLM servers (grep ^VLLM_API_KEY $BIFROST/env/bifrost.env)."
  fi
  env_set "$BIFROST/env/bifrost.env" VLLM_API_KEY "$VLLM_KEY"
  unset VLLM_KEY
fi

BIFROST_JSON=$BIFROST/config/bifrost.json
HASH_BIFROST_BEFORE=$(file_hash "$BIFROST_JSON")
if [ -f "$BIFROST_JSON" ]; then
  info "bifrost/config/bifrost.json exists – models, budgets and keys are kept; only logging switches are updated."
else
  info "Budgets in USD per time window – a request is rejected (HTTP 402) as soon as one of them is used up."
  ask_number B_LC_5H  "LibreChat (all users together): budget per 5 hours"
  ask_number B_LC_1W  "LibreChat: budget per week"
  ask_number B_LC_1M  "LibreChat: budget per month"
  ask_number B_ONYX_1D "Onyx: budget per day"
  ask_number B_ONYX_1M "Onyx: budget per month"
  # external services from bifrost.env (VK_EXT_<NAME>) – budget per day and month for each
  EXT_APPS=""; ext_1d=""; ext_1m=""
  mapfile -t EXT_ENVS < <(sed -n 's/^\(VK_EXT_[A-Z0-9_]*\)=.*/\1/p' "$BIFROST/env/bifrost.env")
  for ext_env in "${EXT_ENVS[@]}"; do
    ext_name=$(printf '%s' "${ext_env#VK_EXT_}" | tr 'A-Z_' 'a-z-')
    ask_number ext_1d "$ext_name: budget per day"
    ask_number ext_1m "$ext_name: budget per month"
    EXT_APPS="$EXT_APPS$ext_name|$ext_env|$ext_1d|$ext_1m;"
  done
  umask 022; mkdir -p "$BIFROST/config"; umask 077
  B_LC_5H=$B_LC_5H B_LC_1W=$B_LC_1W B_LC_1M=$B_LC_1M B_ONYX_1D=$B_ONYX_1D B_ONYX_1M=$B_ONYX_1M \
  EXT_APPS=$EXT_APPS \
  python3 -I - "$BIFROST_JSON" <<'PY'
import json, os, sys
b = lambda k: float(os.environ[k])
claude = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
gpt = ["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"]
def fallback(rid, name, prio, provider, model, target):
    return {"id": rid, "name": name, "enabled": True, "scope": "global", "priority": prio,
            "cel_expression": f'provider == "{provider}" && model.endsWith("{model}")',
            "targets": [{"weight": 1}], "fallbacks": [target]}
def vk(vid, name, desc, env, configs, rate=None):
    d = {"id": vid, "name": name, "description": desc, "value": f"env.{env}", "is_active": True,
         "calendar_aligned": True, "provider_configs": configs}
    if rate:
        d["rate_limit_id"] = rate
    return d
def pc(provider, models):
    return {"provider": provider, "weight": 1, "key_ids": ["*"], "allowed_models": models}
cfg = {
  "source_of_truth": "config.json",
  "encryption_key": "env.BIFROST_ENCRYPTION_KEY",
  "client": {
    "enforce_auth_on_inference": True, "enable_logging": True, "disable_content_logging": True,
    "log_retention_days": 90, "drop_excess_requests": True, "allow_direct_keys": False,
    "max_request_body_size_mb": 50, "allowed_origins": [], "logging_headers": []
  },
  "providers": {
    "anthropic": {"keys": [{"name": "anthropic-main", "value": "env.ANTHROPIC_API_KEY", "weight": 1, "models": claude}]},
    "openai": {"keys": [{"name": "openai-main", "value": "env.OPENAI_API_KEY", "weight": 1, "models": list(gpt)}]}
  },
  "governance": {
    "auth_config": {"is_enabled": True, "admin_username": "env.BIFROST_ADMIN_USER",
                    "admin_password": "env.BIFROST_ADMIN_PASSWORD"},
    "budgets": [
      {"id": "budget-librechat-5h", "max_limit": b("B_LC_5H"), "reset_duration": "5h", "virtual_key_id": "vk-librechat"},
      {"id": "budget-librechat-1w", "max_limit": b("B_LC_1W"), "reset_duration": "1w", "virtual_key_id": "vk-librechat"},
      {"id": "budget-librechat-1M", "max_limit": b("B_LC_1M"), "reset_duration": "1M", "virtual_key_id": "vk-librechat"},
      {"id": "budget-onyx-1d", "max_limit": b("B_ONYX_1D"), "reset_duration": "1d", "virtual_key_id": "vk-onyx"},
      {"id": "budget-onyx-1M", "max_limit": b("B_ONYX_1M"), "reset_duration": "1M", "virtual_key_id": "vk-onyx"}
    ],
    "rate_limits": [],
    "routing_rules": [
      fallback("fb-claude-sonnet", "Fallback Claude Sonnet → GPT-6.1 Sol", 110, "anthropic", "claude-sonnet-5-5", "openai/gpt-6.1-sol"),
      fallback("fb-claude-opus", "Fallback Claude Opus → GPT-6 Astra", 120, "anthropic", "claude-opus-5-5", "openai/gpt-6-astra"),
      fallback("fb-claude-haiku", "Fallback Claude Haiku → GPT-6 Luna", 130, "anthropic", "claude-haiku-5-5", "openai/gpt-6-luna"),
      fallback("fb-gpt-astra", "Fallback GPT-6 Astra → Claude Opus", 140, "openai", "gpt-6-astra", "anthropic/claude-opus-5-5"),
      fallback("fb-gpt-sol", "Fallback GPT-6.1 Sol → Claude Sonnet", 150, "openai", "gpt-6.1-sol", "anthropic/claude-sonnet-5-5"),
      fallback("fb-gpt-terra", "Fallback GPT-6.1 Terra → Claude Sonnet", 160, "openai", "gpt-6.1-terra", "anthropic/claude-sonnet-5-5"),
      fallback("fb-gpt-luna", "Fallback GPT-6 Luna → Claude Haiku", 170, "openai", "gpt-6-luna", "anthropic/claude-haiku-5-5")
    ],
    "virtual_keys": [
      vk("vk-librechat", "librechat", "KIRA (LibreChat) incl. document search, images, speech", "VK_LIBRECHAT",
         [pc("anthropic", list(claude)), pc("openai", list(gpt))]),
      vk("vk-onyx", "onyx", "Onyx (intranet search)", "VK_ONYX",
         [pc("anthropic", ["claude-sonnet-5-5", "claude-haiku-5-5"]), pc("openai", ["gpt-6.1-sol", "gpt-6-luna"])])
    ]
  },
  "config_store": {"enabled": True, "type": "postgres",
                   "config": {"host": "db", "port": "5432", "user": "bifrost", "password": "env.BIFROST_DB_PASSWORD",
                              "db_name": "bifrost", "ssl_mode": "disable"}},
  "logs_store": {"enabled": True, "type": "postgres",
                 "config": {"host": "db", "port": "5432", "user": "bifrost", "password": "env.BIFROST_DB_PASSWORD",
                            "db_name": "bifrost", "ssl_mode": "disable"}}
}
# external services: own key, budget per day/month, 60 requests/minute, Claude Haiku/Sonnet
gov = cfg["governance"]
for entry in filter(None, os.environ.get("EXT_APPS", "").split(";")):
    name, env, day, month = entry.split("|")
    gov["budgets"] += [
        {"id": f"budget-{name}-1d", "max_limit": float(day), "reset_duration": "1d", "virtual_key_id": f"vk-{name}"},
        {"id": f"budget-{name}-1M", "max_limit": float(month), "reset_duration": "1M", "virtual_key_id": f"vk-{name}"},
    ]
    gov["rate_limits"].append({"id": f"rl-{name}", "request_max_limit": 60, "request_reset_duration": "1m"})
    gov["virtual_keys"].append(vk(f"vk-{name}", name, f"External service {name} via the LLM API", env,
                                  [pc("anthropic", ["claude-haiku-5-5", "claude-sonnet-5-5"])], f"rl-{name}"))
if not gov["rate_limits"]:
    del gov["rate_limits"]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
  info "bifrost/config/bifrost.json created."
fi

# Update switches and required models in bifrost.json (on every run; only adds models, never removes them)
EXTRA_MODELS="$EMBEDDING_MODEL"
is_true IMAGE_GENERATION && EXTRA_MODELS="$EXTRA_MODELS $(setup_get IMAGE_MODEL)"
if is_true SPEECH; then
  EXTRA_MODELS="$EXTRA_MODELS $(setup_get STT_MODEL)"
  [ -n "$(setup_get TTS_MODEL)" ] && EXTRA_MODELS="$EXTRA_MODELS $(setup_get TTS_MODEL)"
fi
# CORS: only the Bifrost web interface itself (LibreChat calls Bifrost server-side and needs no CORS; Bifrost always
# allows its own origin and localhost) – keeps scripts on other origins (e.g. the KIRA page) away from the admin API
ORIGINS=""
[ -n "$(setup_get BIFROST_UI_DOMAIN)" ] && ORIGINS="https://$(setup_get BIFROST_UI_DOMAIN)"
log_days=$(days_of "$(setup_get BIFROST_LOG_RETENTION)" 1 3650 || echo 90)
GUARD_ON=false; is_true PRIVACY_GUARD && GUARD_ON=true
GUARD_ON=$GUARD_ON GUARD_MODE=$(setup_get GUARD_MODE) GUARD_PRIVACY_URL=$(setup_get GUARD_PRIVACY_URL) \
GUARD_SAFETY_URL=$(setup_get GUARD_SAFETY_URL) GUARD_ANSWER_URL=$(setup_get GUARD_ANSWER_URL) \
GUARD_EMBEDDING_URL=$(setup_get GUARD_EMBEDDING_URL) GUARD_TIMEOUT=$(setup_get GUARD_TIMEOUT) \
GUARD_BLOCK_CATEGORIES=$(setup_get GUARD_BLOCK_CATEGORIES) GUARD_LOG_CATEGORIES=$(setup_get GUARD_LOG_CATEGORIES) \
SEND_HEADERS=$(setup_get SEND_USER_HEADERS) LOG_CONTENT=$(setup_get LOG_CHAT_CONTENT) LOG_DAYS=${log_days:-90} \
EXTRA_MODELS=$EXTRA_MODELS ORIGINS=$ORIGINS python3 -I - "$BIFROST_JSON" <<'PY'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p, encoding="utf-8"))
before = json.dumps(c, sort_keys=True)
cl = c.setdefault("client", {})
cl["disable_content_logging"] = os.environ["LOG_CONTENT"] != "true"
cl["logging_headers"] = (["x-librechat-user-email", "x-librechat-user-name", "x-librechat-user-id"]
                         if os.environ["SEND_HEADERS"] == "true" else [])
cl["allowed_origins"] = os.environ["ORIGINS"].split()
cl["log_retention_days"] = int(os.environ["LOG_DAYS"])
extra = [m for m in os.environ["EXTRA_MODELS"].split() if m]
keys = c.get("providers", {}).get("openai", {}).get("keys", [])
if keys:
    models = keys[0].setdefault("models", [])
    for m in extra:
        if m not in models:
            models.append(m)
for vk in c.get("governance", {}).get("virtual_keys", []):
    if vk.get("id") != "vk-librechat":
        continue
    for pc in vk.get("provider_configs", []):
        if pc.get("provider") == "openai":
            allowed = pc.setdefault("allowed_models", [])
            for m in extra:
                if m not in allowed:
                    allowed.append(m)
# Privacy guard (kira/PRIVACY-GUARD.md): vLLM provider (local answers, embeddings), vk-librechat may use it, plugin.
# Switched off: all three are removed again, Bifrost works as before.
E = os.environ
lc_vk = next((v for v in c.get("governance", {}).get("virtual_keys", []) if v.get("id") == "vk-librechat"), None)
plugins = [x for x in c.get("plugins", []) if x.get("name") != "privacy-guard"]
if E["GUARD_ON"] == "true":
    def vkey(name, model, url):
        return {"name": name, "value": "env.VLLM_API_KEY", "weight": 1, "models": [model],
                "vllm_key_config": {"url": url.rstrip("/"), "model_name": model}}
    c.setdefault("providers", {})["vllm"] = {
        "keys": [vkey("vllm-answer", "kira-answer", E["GUARD_ANSWER_URL"]),
                 vkey("vllm-embedding", "kira-embedding", E["GUARD_EMBEDDING_URL"])],
        # vLLM is in the LAN: Bifrost blocks private addresses unless allowed; long local answers need time
        "network_config": {"allow_private_network": True, "default_request_timeout_in_seconds": 600,
                           "stream_idle_timeout_in_seconds": 300, "max_retries": 0}}
    if lc_vk is not None:
        pcs = [x for x in lc_vk.get("provider_configs", []) if x.get("provider") != "vllm"]
        pcs.append({"provider": "vllm", "weight": 1, "key_ids": ["*"], "allowed_models": ["kira-answer", "kira-embedding"]})
        lc_vk["provider_configs"] = pcs
    split = lambda s, d: [x.strip() for x in (s or d).split(",") if x.strip()]
    plugins.append({"enabled": True, "name": "privacy-guard", "path": "/app/plugins/privacy-guard.so",
                    "placement": "pre_builtin", "order": 0, "config": {
        "mode": E["GUARD_MODE"] or "observe",
        "privacy_url": E["GUARD_PRIVACY_URL"].rstrip("/"), "privacy_model": "kira-privacy",
        "safety_url": E["GUARD_SAFETY_URL"].rstrip("/"), "safety_model": "kira-safety",
        "answer_model": "vllm/kira-answer",
        "title_alias": "kira/title", "title_model": "anthropic/claude-haiku-5-5",
        "api_key_env": "VLLM_API_KEY", "guarded_key_envs": ["VK_LIBRECHAT"],
        "timeout_seconds": int(E["GUARD_TIMEOUT"] or 8),
        "block_categories": split(E["GUARD_BLOCK_CATEGORIES"],
            "Violent,Non-violent Illegal Acts,Sexual Content or Sexual Acts,Suicide & Self-Harm,Jailbreak"),
        "log_categories": split(E["GUARD_LOG_CATEGORIES"],
            "Unethical Acts,Politically Sensitive Topics,Copyright Violation")}})
else:
    c.get("providers", {}).pop("vllm", None)
    if lc_vk is not None:
        lc_vk["provider_configs"] = [x for x in lc_vk.get("provider_configs", []) if x.get("provider") != "vllm"]
if plugins:
    c["plugins"] = plugins
else:
    c.pop("plugins", None)
if json.dumps(c, sort_keys=True) != before:
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(c, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print("bifrost.json: logging switches, retention, models (embeddings/images/speech) and/or privacy guard updated.")
PY
chmod 644 "$BIFROST_JSON"
HASH_BIFROST_AFTER=$(file_hash "$BIFROST_JSON")

# ---------------------------------------------------------------- 4. KIRA / LibreChat
section "KIRA (LibreChat)"
LC_ENV=$KIRA/env/librechat.env
LC_EXISTED=false; [ -f "$LC_ENV" ] && LC_EXISTED=true
if [ -f "$LC_ENV" ]; then
  info "kira/env/librechat.env exists – secrets unchanged."
else
  KC_FILE=$KIRA/env/keycloak-client.env
  if [ -f "$KC_FILE" ]; then
    sed -i 's/\r$//' "$KC_FILE"
    CLIENT_ID=$(env_get "$KC_FILE" OAUTH_CLIENT_ID)
    CLIENT_SECRET=$(env_get "$KC_FILE" OAUTH_CLIENT_SECRET)
    ISSUER=$(env_get "$KC_FILE" OPENID_PROVIDER_URL); ISSUER=${ISSUER%/.well-known/openid-configuration}
    [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] && [ -n "$ISSUER" ] || die "$KC_FILE is incomplete."
    info "Keycloak client $CLIENT_ID taken from env/keycloak-client.env ($ISSUER)."
  else
    info "Keycloak client: values from the Keycloak server (or place the file at $KC_FILE and run setup.sh again)."
    ask ISSUER        "Keycloak issuer (https://id.example.com/realms/<realm>)"
    ask CLIENT_ID     "Keycloak client ID"
    ask CLIENT_SECRET "Keycloak client secret" secret
  fi
  ISSUER=${ISSUER%/}
  [[ $ISSUER == https://*/realms/* ]] || die "unexpected issuer '$ISSUER' (expected https://…/realms/<realm>)."
  MONGO_PW=$(random_hex 24); MEILI_KEY=$(random_hex 24); JWT=$(random_hex); RAG_PW=$(random_hex 24)
  cat > "$KIRA/env/mongodb.env" <<EOF
# MongoDB – generated by setup.sh. Only takes effect on first start (empty volume).
MONGO_INITDB_ROOT_USERNAME=librechat
MONGO_INITDB_ROOT_PASSWORD=$MONGO_PW
EOF
  printf '# Meilisearch – generated by setup.sh\nMEILI_MASTER_KEY=%s\n' "$MEILI_KEY" > "$KIRA/env/meilisearch.env"
  cat > "$KIRA/env/vectordb.env" <<EOF
# pgvector for the RAG API – generated by setup.sh. Only takes effect on first start (empty volume).
POSTGRES_DB=rag
POSTGRES_USER=rag
POSTGRES_PASSWORD=$RAG_PW
EOF
  cat > "$KIRA/env/rag.env" <<EOF
# RAG API (document search) – generated by setup.sh. JWT_SECRET must match the one in librechat.env.
POSTGRES_DB=rag
POSTGRES_USER=rag
POSTGRES_PASSWORD=$RAG_PW
JWT_SECRET=$JWT
EMBEDDINGS_PROVIDER=openai
EMBEDDINGS_MODEL=openai/$EMBEDDING_MODEL
RAG_OPENAI_API_KEY=$VK_LIBRECHAT
RAG_OPENAI_BASEURL=http://bifrost:8080/v1
EOF
  cat > "$LC_ENV" <<EOF
# LibreChat – generated by setup.sh. Values marked "(setup)" are updated by setup.sh on every run.
HOST=0.0.0.0
PORT=3080
NODE_ENV=production
DOMAIN_CLIENT=https://$DOMAIN
DOMAIN_SERVER=https://$DOMAIN
NO_INDEX=true
APP_TITLE=KIRA
HELP_AND_FAQ_URL=/
CUSTOM_FOOTER="KIRA · Antworten können Fehler enthalten – bitte prüfen."
MONGO_URI=mongodb://librechat:$MONGO_PW@mongodb:27017/LibreChat?authSource=admin
CREDS_KEY=$(random_hex 32)
CREDS_IV=$(random_hex 16)
JWT_SECRET=$JWT
JWT_REFRESH_SECRET=$(random_hex)
# Chat search
SEARCH=true
MEILI_HOST=http://meilisearch:7700
MEILI_MASTER_KEY=$MEILI_KEY
MEILI_NO_ANALYTICS=true
# Document search
RAG_API_URL=http://rag_api:8000
# Login via Keycloak SSO only (roles from the "roles" claim in the ID token)
ALLOW_EMAIL_LOGIN=false
ALLOW_REGISTRATION=false
ALLOW_SOCIAL_LOGIN=true
ALLOW_SOCIAL_REGISTRATION=true
ALLOW_PASSWORD_RESET=false
ALLOW_ACCOUNT_DELETION=false
ALLOW_SHARED_LINKS=false
ALLOW_SHARED_LINKS_PUBLIC=false
OPENID_ISSUER=$ISSUER
OPENID_CLIENT_ID=$CLIENT_ID
OPENID_CLIENT_SECRET=$CLIENT_SECRET
OPENID_SESSION_SECRET=$(random_hex)
OPENID_SCOPE="openid profile email"
OPENID_CALLBACK_URL=/oauth/openid/callback
OPENID_REQUIRED_ROLE=user,admin
OPENID_REQUIRED_ROLE_TOKEN_KIND=id
OPENID_REQUIRED_ROLE_PARAMETER_PATH=roles
OPENID_ADMIN_ROLE=admin
OPENID_ADMIN_ROLE_TOKEN_KIND=id
OPENID_ADMIN_ROLE_PARAMETER_PATH=roles
OPENID_BUTTON_LABEL="Anmelden"
OPENID_AUTO_REDIRECT=true
OPENID_USE_PKCE=true
OPENID_USE_END_SESSION_ENDPOINT=true
# Many users behind one shared IP (NAT): IP limits and IP bans would hit everyone
LIMIT_MESSAGE_IP=false
LOGIN_MAX=300
LOGIN_WINDOW=5
BAN_VIOLATIONS=false
# Bifrost (virtual key vk-librechat) – chat, images, speech
BIFROST_API_KEY=$VK_LIBRECHAT
IMAGE_GEN_OAI_API_KEY=$VK_LIBRECHAT
IMAGE_GEN_OAI_BASEURL=http://bifrost:8080/v1
STT_API_KEY=$VK_LIBRECHAT
TTS_API_KEY=$VK_LIBRECHAT
# Web search (stack websearch, internal only) – Firecrawl without its own authentication, the key is a placeholder
SEARXNG_INSTANCE_URL=http://searxng:8080
FIRECRAWL_API_URL=http://firecrawl:3002
FIRECRAWL_API_KEY=fc-$(random_hex 16)
FIRECRAWL_VERSION=v2
# Intranet (Onyx): API key from the Onyx admin area (README) – empty = agent "Intranet" hidden
ONYX_API_KEY=
DEBUG_LOGGING=false
CONSOLE_JSON=false
EOF
  unset CLIENT_SECRET MONGO_PW MEILI_KEY JWT RAG_PW
  info "kira/env/librechat.env, mongodb.env, meilisearch.env, vectordb.env, rag.env created."
fi
# (setup) update derived values on every run
# Login duration: the LibreChat session (refresh token) is valid this long from login, then SSO again
env_set "$LC_ENV" REFRESH_TOKEN_EXPIRY "$login_ms"
if [ -n "$UPSTREAM_IP" ]; then env_set "$LC_ENV" TRUST_PROXY 2; else env_set "$LC_ENV" TRUST_PROXY 1; fi
# Message limit per user (per minute; when exceeded the user gets a notice, no ban – BAN_VIOLATIONS=false)
msg_limit=$(setup_get MESSAGE_LIMIT); msg_limit=${msg_limit:-20}
if [ "$msg_limit" = 0 ]; then
  env_set "$LC_ENV" LIMIT_MESSAGE_USER false
else
  env_set "$LC_ENV" LIMIT_MESSAGE_USER true
  env_set "$LC_ENV" MESSAGE_USER_MAX "$msg_limit"
  env_set "$LC_ENV" MESSAGE_USER_WINDOW 1
fi
# Document search: with the privacy guard the embeddings are computed locally (vLLM), otherwise by OpenAI
RAG_ENV=$KIRA/env/rag.env
EMB_BEFORE=$(env_get "$RAG_ENV" EMBEDDINGS_MODEL)
if is_true PRIVACY_GUARD; then
  env_set "$RAG_ENV" EMBEDDINGS_MODEL "vllm/kira-embedding"
  env_set "$RAG_ENV" RAG_CHECK_EMBEDDING_CTX_LENGTH false   # no OpenAI tokenizer: send text, not token IDs
else
  env_set "$RAG_ENV" EMBEDDINGS_MODEL "openai/$EMBEDDING_MODEL"
  env_set "$RAG_ENV" RAG_CHECK_EMBEDDING_CTX_LENGTH true
fi
if [ "$LC_EXISTED" = true ] && [ -n "$EMB_BEFORE" ] && [ "$EMB_BEFORE" != "$(env_get "$RAG_ENV" EMBEDDINGS_MODEL)" ]; then
  warn "Document search: embedding model changed ($EMB_BEFORE -> $(env_get "$RAG_ENV" EMBEDDINGS_MODEL)). Documents uploaded before cannot be searched any more – users have to upload them again."
fi
# Help link in the user menu ("/" hides the entry)
help_url=$(setup_get HELP_URL); env_set "$LC_ENV" HELP_AND_FAQ_URL "${help_url:-/}"
# Create the terms of use text once from the template (freely editable afterwards)
if is_true TERMS_ENABLED && [ ! -f "$KIRA/config/terms-of-use.md" ]; then
  install -m 644 "$KIRA/terms-of-use.md.example" "$KIRA/config/terms-of-use.md"
  warn "Terms of use: template copied to $KIRA/config/terms-of-use.md – fill in the contact line (last line); deletion periods are filled in from setup.env."
fi
if is_true IMAGE_GENERATION; then env_set "$LC_ENV" IMAGE_GEN_OAI_MODEL "openai/$(setup_get IMAGE_MODEL)"; fi
if is_true ONYX_ENABLED && [ -z "$(env_get "$LC_ENV" ONYX_API_KEY)" ]; then
  info "Agent \"Intranet\": the Onyx API key is still missing. It is created in the Onyx admin area (README, section Onyx)."
  ask_optional ONYX_KEY "Onyx API key (empty = later, then run setup.sh again)" secret
  [ -n "$ONYX_KEY" ] && env_set "$LC_ENV" ONYX_API_KEY "$ONYX_KEY" && info "ONYX_API_KEY stored."
  unset ONYX_KEY
fi

ISSUER=$(env_get "$LC_ENV" OPENID_ISSUER)
KC_HOST=$(printf '%s' "$ISSUER" | sed -E 's#^https://([^/:]+).*#\1#')
compose_env() {   # compose_env <file> – Keycloak address for extra_hosts (empty = normal DNS)
  {
    echo "# generated by /opt/kira/setup.sh on every run – Keycloak directly in the LAN (extra_hosts), empty = DNS"
    if [ -n "$KC_IP" ]; then echo "KEYCLOAK_HOST=$KC_HOST"; echo "KEYCLOAK_IP=$KC_IP"
    else echo "KEYCLOAK_HOST="; echo "KEYCLOAK_IP="; fi
  } > "$1"
  chmod 600 "$1"
}
compose_env "$KIRA/env/compose.env"

# ---------------------------------------------------------------- 4b. Code interpreter (optional, stack codeinterpreter)
section "Code interpreter"
CODE_KEYS=(LIBRECHAT_CODE_BASEURL CODEAPI_AUTH_PROVIDER CODEAPI_JWT_ALGORITHM CODEAPI_JWT_KID CODEAPI_JWT_ISSUER
           CODEAPI_JWT_AUDIENCE CODEAPI_JWT_TTL_SECONDS CODEAPI_JWT_SINGLE_TENANT_ID)
sed -i '/^OFFICE_MCP_API_KEY=/d' "$LC_ENV"   # earlier test version (office download links), replaced by the code interpreter
CODE_VERSION=""
if is_true CODE_INTERPRETER; then
  CODE_ENV=$CODEI/env/codeapi.env
  CODE_VERSION=$(env_get "$CODEI/env/versions.env" CODEAPI_VERSION)
  [[ $CODE_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "CODEAPI_VERSION=$CODE_VERSION in $CODEI/env/versions.env – a release tag like v1.9.1."
  # sources of the pinned release (built into images when starting)
  if [ ! -d "$CODEI/src/.git" ]; then
    info "Cloning ClickHouse/code-interpreter $CODE_VERSION …"
    rm -rf "$CODEI/src"
    # umask 022: the images copy the files with their permissions – services that run as a user must read them
    (umask 022; git clone -q --depth 1 --branch "$CODE_VERSION" -c advice.detachedHead=false \
      https://github.com/ClickHouse/code-interpreter "$CODEI/src") \
      || die "code interpreter $CODE_VERSION could not be cloned (GitHub reachable? tag correct?)."
  elif [ "$(git -C "$CODEI/src" describe --tags --exact-match 2>/dev/null)" != "$CODE_VERSION" ]; then
    info "Code interpreter: switching sources to $CODE_VERSION …"
    (umask 022; git -C "$CODEI/src" fetch -q --depth 1 origin tag "$CODE_VERSION" \
      && git -C "$CODEI/src" -c advice.detachedHead=false checkout -q -f "$CODE_VERSION") \
      || die "code interpreter $CODE_VERSION could not be fetched (GitHub reachable? tag correct?)."
  fi
  # LibreChat signs a short token (Ed25519, 5 minutes) per request; the code interpreter knows only the public key
  if [ -z "$(env_get "$LC_ENV" CODEAPI_JWT_PRIVATE_KEY_BASE64)" ]; then
    env_set "$LC_ENV" CODEAPI_JWT_PRIVATE_KEY_BASE64 "$(openssl genpkey -algorithm ed25519 2>/dev/null | base64 -w0)"
    info "Key pair for the code interpreter generated (private key in env/librechat.env)."
  fi
  env_set "$LC_ENV" LIBRECHAT_CODE_BASEURL "http://codeapi:3112/v1"
  env_set "$LC_ENV" CODEAPI_AUTH_PROVIDER librechat-jwt
  env_set "$LC_ENV" CODEAPI_JWT_ALGORITHM EdDSA
  env_set "$LC_ENV" CODEAPI_JWT_KID kira-1
  env_set "$LC_ENV" CODEAPI_JWT_ISSUER librechat
  env_set "$LC_ENV" CODEAPI_JWT_AUDIENCE codeapi
  env_set "$LC_ENV" CODEAPI_JWT_TTL_SECONDS 300
  env_set "$LC_ENV" CODEAPI_JWT_SINGLE_TENANT_ID kira
  # secrets of the code interpreter – once
  if [ ! -f "$CODE_ENV" ]; then
    m_priv=$(openssl genpkey -algorithm ed25519 -outform DER 2>/dev/null | base64 -w0)
    m_pub=$(printf '%s' "$m_priv" | base64 -d | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | base64 -w0)
    [ -n "$m_pub" ] || die "openssl cannot create Ed25519 keys – needed for the code interpreter."
    {
      echo "# code interpreter – generated by setup.sh (secrets, never overwritten; the last lines are derived on every run)"
      echo "REDIS_PASSWORD=$(random_hex 24)"
      echo "MINIO_ROOT_USER=codeapi$(random_hex 4)"
      echo "MINIO_ROOT_PASSWORD=$(random_hex 24)"
      echo "CODEAPI_INTERNAL_SERVICE_TOKEN=$(random_hex 32)"
      echo "CODEAPI_EGRESS_GRANT_SECRET=$(random_hex 32)"
      echo "CODEAPI_EXECUTION_MANIFEST_PRIVATE_KEY=$m_priv"
      echo "SANDBOX_EXECUTION_MANIFEST_PUBLIC_KEY=$m_pub"
    } > "$CODE_ENV"
    unset m_priv m_pub
    info "codeinterpreter/env/codeapi.env created."
  fi
  # derived on every run: public key of LibreChat (JWKS, JSON in single quotes) and parallel runs
  x=$(env_get "$LC_ENV" CODEAPI_JWT_PRIVATE_KEY_BASE64 | base64 -d | openssl pkey -pubout -outform DER 2>/dev/null \
      | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')
  [ ${#x} -eq 43 ] || die "public key of the code interpreter could not be derived (openssl with Ed25519 needed)."
  sed -i '/^CODEAPI_JWT_JWKS_JSON=/d; /^CODE_PARALLEL=/d' "$CODE_ENV"
  printf '%s\n' "CODEAPI_JWT_JWKS_JSON='{\"keys\":[{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"$x\",\"kid\":\"kira-1\",\"alg\":\"EdDSA\",\"use\":\"sig\"}]}'" >> "$CODE_ENV"
  n=$(setup_get CODE_PARALLEL); echo "CODE_PARALLEL=${n:-4}" >> "$CODE_ENV"
  # RAM: KIRA about 8 GB (+16 GB with Onyx), the code interpreter 2 GB for its services + 2 GB per parallel run
  need=$(( 8 + 2 + 2 * ${n:-4} )); is_true ONYX_ENABLED && need=$((need + 16))
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  [ "${mem_kb:-0}" -ge $((need * 1000000)) ] \
    || warn "The host has $((mem_kb / 1024 / 1024)) GB of RAM; about $need GB are recommended with the code interpreter (fewer parallel runs: CODE_PARALLEL)."
  rm -f "$KIRA/config/codeapi-jwks.json"   # earlier test version: public key for an external code server
  info "Code interpreter $CODE_VERSION prepared (LibreChat -> http://codeapi:3112, network kira-code)."
else
  info "Code interpreter is off (CODE_INTERPRETER=false)."
  for k in "${CODE_KEYS[@]}"; do sed -i "/^$k=/d" "$LC_ENV"; done   # the key pair stays for a later switch-on
fi

section "KIRA configuration (librechat.yaml)"
HASH_LC_BEFORE=$(file_hash "$KIRA/config/librechat.yaml")
# Branding (logo, favicons, app manifest) is mounted file by file – a missing file would become an empty directory
BRANDING_FILES="favicon-16x16.png favicon-32x32.png apple-touch-icon-180x180.png icon-192x192.png maskable-icon.png logo.svg manifest.webmanifest"
for f in $BRANDING_FILES; do
  [ -s "$KIRA/branding/$f" ] || die "branding/$f is missing – copy it from the package (README, section \"Branding\")."
done
umask 022; mkdir -p "$KIRA/config"; umask 077
# Agents per group: create the mapping once from the template (a new package does not overwrite it)
if [ ! -f "$KIRA/agents/groups.env" ]; then
  install -m 644 "$KIRA/agents/groups.env.example" "$KIRA/agents/groups.env"
  info "agents/groups.env created from the template."
fi
KIRA_DIR=$KIRA python3 -I "$KIRA/scripts/librechat-config.py"
HASH_LC_AFTER=$(file_hash "$KIRA/config/librechat.yaml")
# a replaced branding file only reaches the container after a restart (bind mount keeps the old file)
BRANDING_STAMP=$KIRA/config/branding.sha256
HASH_BRANDING=$(cd "$KIRA/branding" && file_hash $BRANDING_FILES)
if [ "$HASH_BRANDING" != "$(cat "$BRANDING_STAMP" 2>/dev/null)" ]; then
  [ -f "$BRANDING_STAMP" ] && info "Branding changed – LibreChat will be restarted."
  HASH_LC_AFTER="$HASH_LC_AFTER+branding"
  (umask 022; echo "$HASH_BRANDING" > "$BRANDING_STAMP")
fi

# Own agents (BUILDER_GROUP + builder.<model group>=… in agents/groups.env): Keycloak service account for builder-sync.py
has_builders() {
  python3 -I -c 'import json, sys; p = json.load(open(sys.argv[1])); sys.exit(0 if p.get("enabled") and p.get("builders") else 1)' \
    "$KIRA/config/agent-groups.json" 2>/dev/null
}
KS=$KIRA/env/keycloak-sync.env
if has_builders && [ -z "$(env_get "$KS" KC_SYNC_CLIENT_SECRET)" ]; then
  info "Own agents are defined in agents/groups.env – reading the group members needs a Keycloak service account"
  info "(confidential client with \"Service accounts roles\", roles view-users and query-groups – README, section \"Own agents\")."
  ask_optional KC_SYNC_ID "Client ID of the service account (empty = kira-sync)"
  ask_optional KC_SYNC_SECRET "Its client secret (empty = enter later in env/keycloak-sync.env)" secret
  printf '# Keycloak service account for scripts/builder-sync.py (realm-management: view-users, query-groups)\nKC_SYNC_CLIENT_ID=%s\nKC_SYNC_CLIENT_SECRET=%s\n' \
    "${KC_SYNC_ID:-kira-sync}" "$KC_SYNC_SECRET" > "$KS"
  chmod 600 "$KS"
  if [ -n "$KC_SYNC_SECRET" ]; then
    info "env/keycloak-sync.env written."
  else
    warn "No secret – nobody gets own agents until KC_SYNC_CLIENT_SECRET is set in env/keycloak-sync.env."
  fi
  unset KC_SYNC_ID KC_SYNC_SECRET
fi

# ---------------------------------------------------------------- 5. Web search
section "Web search (SearXNG, Firecrawl)"
if [ -f "$WEBSEARCH/env/searxng.env" ]; then
  info "websearch/env/searxng.env exists – unchanged."
else
  printf '# SearXNG – generated by setup.sh\nSEARXNG_SECRET=%s\n' "$(random_hex)" > "$WEBSEARCH/env/searxng.env"
  info "websearch/env/searxng.env created."
fi
if [ -f "$WEBSEARCH/env/firecrawl.env" ]; then
  info "websearch/env/firecrawl.env exists – unchanged."
else
  printf '# Firecrawl (queue) – generated by setup.sh\nPOSTGRES_PASSWORD=%s\n' "$(random_hex 24)" > "$WEBSEARCH/env/firecrawl.env"
  info "websearch/env/firecrawl.env created."
fi

# ---------------------------------------------------------------- 6. Onyx (optional)
section "Onyx (intranet search)"
if is_true ONYX_ENABLED; then
  if [ -f "$ONYX/env/onyx.env" ]; then
    info "onyx/env/onyx.env exists – unchanged."
  else
    OS_PW="Os$(random_hex 16)A1!"      # OpenSearch requires upper/lower case letters, a digit and a special character
    cat > "$ONYX/env/onyx.env" <<EOF
# Onyx – generated by setup.sh. Passwords only take effect on first start (empty volumes).
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$(random_hex 24)
USER_AUTH_SECRET=$(random_hex)
ENCRYPTION_KEY_SECRET=$(random_hex 16)
OPENSEARCH_ADMIN_PASSWORD=$OS_PW
WEB_DOMAIN=https://$(setup_get ONYX_DOMAIN)
MCP_SERVER_ENABLED=true
LOG_LEVEL=info
EOF
    printf '# OpenSearch for Onyx – generated by setup.sh (same as OPENSEARCH_ADMIN_PASSWORD in onyx.env)\nOPENSEARCH_INITIAL_ADMIN_PASSWORD=%s\n' \
      "$OS_PW" > "$ONYX/env/opensearch.env"
    unset OS_PW
    info "onyx/env/onyx.env and opensearch.env created."
  fi
  compose_env "$ONYX/env/compose.env"
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  [ "${mem_kb:-0}" -ge 25000000 ] \
    || warn "The host has $((mem_kb / 1024 / 1024)) GB of RAM. 24 GB or more is recommended for Onyx plus everything else."
  mmc=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
  [ "$mmc" -ge 262144 ] \
    || warn "vm.max_map_count is $mmc – OpenSearch needs 262144. Set it on the host (for LXC: on the Proxmox host):
  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf && sysctl --system"
else
  info "Onyx is off (ONYX_ENABLED=false) – stack onyx is not set up."
  [ -f "$ONYX/env/compose.env" ] || compose_env "$ONYX/env/compose.env"
fi

# ---------------------------------------------------------------- 7. Caddy
section "Caddy (reverse proxy)"
SITES=$CADDY/config/sites
umask 022; mkdir -p "$SITES"
HASH_CADDY_BEFORE=$(file_hash "$CADDY/config/Caddyfile" "$SITES"/*.caddy "$SITES"/kira.d/*.caddy)
{
  cat <<EOF
# ============================================================================
# GENERATED by /opt/kira/setup.sh on every run – do NOT edit the global options here by hand,
# use /opt/kira/env/setup.env instead. Site blocks: /opt/caddy/config/sites/*.caddy (never overwritten).
# Reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# ============================================================================
{
	auto_https disable_redirects
	acme_ca https://acme-v02.api.letsencrypt.org/directory
	email $(setup_get ACME_EMAIL)
EOF
  if [ -n "$UPSTREAM_IP" ]; then
    cat <<EOF
	# Port 443 terminates at the upstream proxy ($UPSTREAM_IP) – certificates here via HTTP-01 only
	cert_issuer acme {
		disable_tlsalpn_challenge
	}
	servers {
		# only the upstream proxy is trusted for the client IP from X-Forwarded-For
		trusted_proxies static $UPSTREAM_IP/32
		trusted_proxies_strict
	}
EOF
  fi
  cat <<'EOF'
}

import /etc/caddy/sites/*.caddy
EOF
} > "$CADDY/config/Caddyfile"

SEC_HEADERS='	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}'

if [ -f "$SITES/kira.caddy" ]; then info "sites/kira.caddy exists – unchanged."; else
  cat > "$SITES/kira.caddy" <<EOF
# KIRA (LibreChat) – generated by setup.sh, freely editable afterwards. Reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile
http://$DOMAIN {
	redir https://$DOMAIN{uri} permanent
}

https://$DOMAIN {
	# Access from fixed IPs only: enable both lines and enter the IPs
	#@blocked not client_ip 192.0.2.10 198.51.100.0/24
	#respond @blocked 404
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
		Permissions-Policy "camera=(), geolocation=(), microphone=(self)"
		-Server
	}
	request_body {
		max_size 50MB
	}
	# interface language German (LibreChat otherwise follows the browser language): the cookie "lang" is only set
	# while the browser has none – users can still switch the language in the settings
	@nolang not header_regexp Cookie (^|;\s*)lang=
	header @nolang +Set-Cookie "lang=de-DE; Path=/; Max-Age=31536000; SameSite=Lax; Secure"
	# additional routes of optional components (setup.sh): sites/kira.d/*.caddy
	import /etc/caddy/sites/kira.d/*.caddy
	reverse_proxy librechat:3080
}
EOF
  info "sites/kira.caddy created for $DOMAIN."
fi
# routes of optional components inside the KIRA site – older kira.caddy files get the import line once
mkdir -p "$SITES/kira.d"
printf '# Routes of optional KIRA components, generated by setup.sh – imported by ../kira.caddy\n' > "$SITES/kira.d/00-readme.caddy"
if ! grep -q 'import /etc/caddy/sites/kira.d/' "$SITES/kira.caddy"; then
  if grep -q '^[[:space:]]*reverse_proxy librechat:3080' "$SITES/kira.caddy"; then
    sed -i 's|^\([[:space:]]*\)reverse_proxy librechat:3080|\1import /etc/caddy/sites/kira.d/*.caddy\n\1reverse_proxy librechat:3080|' "$SITES/kira.caddy"
    info "sites/kira.caddy: import of sites/kira.d/ added."
  else
    warn "sites/kira.caddy: line \"reverse_proxy librechat:3080\" not found – add \"import /etc/caddy/sites/kira.d/*.caddy\" in front of the reverse_proxy yourself."
  fi
fi
rm -f "$SITES/kira.d/office.caddy"   # earlier test version (office download links)
if is_true ONYX_ENABLED; then
  OD=$(setup_get ONYX_DOMAIN)
  if [ -f "$SITES/onyx.caddy.off" ] && [ ! -f "$SITES/onyx.caddy" ]; then mv "$SITES/onyx.caddy.off" "$SITES/onyx.caddy"; fi
  if [ -f "$SITES/onyx.caddy" ]; then info "sites/onyx.caddy exists – unchanged."; else
    cat > "$SITES/onyx.caddy" <<EOF
# Onyx (admin interface of the intranet search) – generated by setup.sh, freely editable afterwards
http://$OD {
	redir https://$OD{uri} permanent
}

https://$OD {
	# admins only (ONYX_ALLOWED_IPS): Onyx has open sign-up, the first account becomes admin
	@blocked not client_ip $(setup_get ONYX_ALLOWED_IPS)
	respond @blocked 404
$SEC_HEADERS
	reverse_proxy onyx-nginx:80
}
EOF
    info "sites/onyx.caddy created for $OD."
  fi
elif [ -f "$SITES/onyx.caddy" ]; then
  mv "$SITES/onyx.caddy" "$SITES/onyx.caddy.off"; info "Onyx off – sites/onyx.caddy moved to onyx.caddy.off."
fi

LD=$(setup_get LLM_API_DOMAIN)
if [ -n "$LD" ] && [ ! -f "$SITES/llm.caddy" ]; then
  cat > "$SITES/llm.caddy" <<EOF
# LLM API (OpenAI-compatible access for external applications) – generated by setup.sh, freely editable afterwards.
# Allowed IPs only, OpenAI-compatible endpoints only; management (/api/*), web interface and /health are blocked.
# Access additionally requires the service's own virtual key (VK_EXT_<NAME> from /opt/bifrost/env/bifrost.env).
http://$LD {
	redir https://$LD{uri} permanent
}

https://$LD {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		-Server
	}
	route {
		@denied not client_ip $(setup_get LLM_API_ALLOWED_IPS)
		respond @denied 403

		@api path /v1/chat/completions /v1/responses /v1/models
		request_body @api {
			max_size 10MB
		}
		reverse_proxy @api bifrost:8080

		respond 404
	}
}
EOF
  info "sites/llm.caddy created for $LD."
fi

BD=$(setup_get BIFROST_UI_DOMAIN)
if [ -n "$BD" ] && [ ! -f "$SITES/bifrost.caddy" ]; then
  cat > "$SITES/bifrost.caddy" <<EOF
# Bifrost web interface from outside – generated by setup.sh. Protection: 1. allowed IPs only  2. Bifrost login
http://$BD {
	redir https://$BD{uri} permanent
}

https://$BD {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "same-origin"
		-Server
	}
	route {
		@denied not client_ip $(setup_get BIFROST_UI_ALLOWED_IPS)
		respond @denied 404

		reverse_proxy bifrost:8080
	}
}
EOF
  info "sites/bifrost.caddy created for $BD."
fi

if [ ! -f "$SITES/bifrost-ui-local.caddy" ]; then
  cat > "$SITES/bifrost-ui-local.caddy" <<'EOF'
# Bifrost web interface, local only: Caddy port 8081 is bound to 127.0.0.1:8080 on the host (compose.yml).
# Access via SSH tunnel: ssh -L 8080:127.0.0.1:8080 root@<host>, then http://localhost:8080
http://:8081 {
	reverse_proxy bifrost:8080
}
EOF
fi
umask 077
HASH_CADDY_AFTER=$(file_hash "$CADDY/config/Caddyfile" "$SITES"/*.caddy "$SITES"/kira.d/*.caddy)

# ---------------------------------------------------------------- 8. Docker networks between the stacks
section "Docker networks"
create_net() {   # create_net <name> <subnet> [ip-range]
  if docker network inspect "$1" >/dev/null 2>&1; then
    info "Network $1 exists."
  else
    docker network create --internal --subnet "$2" ${3:+--ip-range "$3"} "$1" >/dev/null \
      || die "network $1 ($2) could not be created – subnet already in use? docker network ls"
    info "Network $1 (internal, $2) created."
  fi
}
create_net kira-proxy  172.30.20.0/24 172.30.20.128/25   # Caddy has the fixed address .2
create_net kira-llm    172.30.21.0/24
create_net kira-search 172.30.22.0/24
create_net kira-onyx   172.30.23.0/24
create_net kira-code   172.30.29.0/24                     # LibreChat -> code interpreter API

# ---------------------------------------------------------------- 9. LAN block (host firewall)
section "LAN block"
EGRESS_ENV=$KIRA/config/egress.env
ALLOW=""
if [ -n "$KC_IP" ] && is_private_ip "$KC_IP"; then ALLOW="$KC_IP"; fi
for ip in $( { getent ahostsv4 "$KC_HOST" 2>/dev/null || true; } | awk '{print $1}' | sort -u); do
  is_private_ip "$ip" && ALLOW="$ALLOW $ip"
done
# shellcheck disable=SC2086  # word splitting intended
ALLOW=$(printf '%s\n' $ALLOW | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
# LibreChat only needs Keycloak from outside – with Keycloak in the LAN (KEYCLOAK_INTERNAL_IP or a private DNS
# answer) it needs no internet at all
LC_ONLY="$ALLOW"
RESOLV=/etc/resolv.conf; [ -f /run/systemd/resolve/resolv.conf ] && RESOLV=/run/systemd/resolve/resolv.conf
DNS=$(awk '$1=="nameserver" && $2 !~ /^127\./ && $2 !~ /:/ {print $2}' "$RESOLV" | sort -u | tr '\n' ' ' | sed 's/ $//')
# Privacy guard: Bifrost may reach exactly the vLLM servers (host:port) in the LAN
GUARD_DST=""
if is_true PRIVACY_GUARD; then
  for key in GUARD_PRIVACY_URL GUARD_SAFETY_URL GUARD_EMBEDDING_URL GUARD_ANSWER_URL; do
    url=$(setup_get "$key"); hp=${url#*://}; hp=${hp%%/*}; host=${hp%%:*}; port=${hp##*:}
    [ "$port" = "$hp" ] && { case "$url" in https:*) port=443 ;; *) port=80 ;; esac; }
    if [[ $host =~ $IPV4_RE ]]; then ips=$host
    else ips=$( { getent ahostsv4 "$host" 2>/dev/null || true; } | awk '{print $1}' | sort -u | tr '\n' ' '); fi
    [ -n "$ips" ] || warn "Privacy guard: $host ($key) cannot be resolved – no firewall exception."
    for ip in $ips; do GUARD_DST="$GUARD_DST $ip:$port"; done
  done
  # shellcheck disable=SC2086  # word splitting intended
  GUARD_DST=$(printf '%s\n' $GUARD_DST | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
fi
umask 022
cat > "$EGRESS_ENV" <<EOF
# LAN block – generated by setup.sh on every run (do not edit by hand)
# Internal destinations that stay reachable despite the block (port 443 only) – Keycloak ($KC_HOST)
ALLOW_PRIVATE_DST="$ALLOW"
# DNS servers of the host (port 53 only) – from $RESOLV
ALLOW_DNS="$DNS"
# Keycloak in the LAN: LibreChat gets no internet, only Keycloak:443 and DNS (empty = internet as the other stacks)
LIBRECHAT_ONLY_DST="$LC_ONLY"
# Privacy guard: vLLM servers in the LAN that Bifrost (bifrost-outbound) may reach, as ip:port (empty = none)
BIFROST_LAN_DST="$GUARD_DST"
EOF
umask 077
UNIT=/etc/systemd/system/kira-egress-firewall.service
if is_true LAN_BLOCK; then
  if command -v systemctl >/dev/null && [ -d /run/systemd/system ] && command -v iptables >/dev/null; then
    umask 022
    cat > "$UNIT" <<'EOF'
[Unit]
Description=KIRA – container networks without access to LAN and host (LAN block)
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/kira/scripts/egress-firewall.sh apply
ExecStop=/opt/kira/scripts/egress-firewall.sh remove

[Install]
WantedBy=multi-user.target docker.service
EOF
    umask 077
    systemctl daemon-reload || warn "systemctl daemon-reload failed"
    systemctl enable kira-egress-firewall.service >/dev/null 2>&1 || true
    if systemctl restart kira-egress-firewall.service; then
      info "LAN block active${ALLOW:+ (exception Keycloak: $ALLOW:443)}."
    else
      warn "LAN block not active – journalctl -u kira-egress-firewall"
    fi
    if [ -z "$ALLOW" ]; then
      info "Note: no internal Keycloak address – Keycloak is reached via the internet."
    fi
  else
    warn "LAN block not set up (systemd or iptables missing) – manually: $KIRA/scripts/egress-firewall.sh apply"
  fi
else
  if [ -f "$UNIT" ]; then
    systemctl disable --now kira-egress-firewall.service >/dev/null 2>&1 || true
    rm -f "$UNIT"; systemctl daemon-reload >/dev/null 2>&1 || true
    info "LAN block removed (LAN_BLOCK=false)."
  else
    info "LAN block off (LAN_BLOCK=false)."
  fi
fi

# ---------------------------------------------------------------- 10. Monitoring, backup
section "Monitoring and backup"
MON_ENV=$KIRA/env/monitoring.env
if [ -f "$MON_ENV" ]; then
  info "kira/env/monitoring.env exists – unchanged."
else
  ask_optional SLACK_URL   "Slack incoming webhook URL for budget warnings and errors (empty = no Slack)" secret
  ask_optional KUMA_HEALTH "Uptime Kuma push URL for the container health (empty = none)"
  ask_optional KUMA_BACKUP "Uptime Kuma push URL for the backup (empty = none)"
  KUMA_RES=""
  if [ -n "$KUMA_HEALTH$KUMA_BACKUP" ]; then
    ask_optional KUMA_IP "Internal IP through which Uptime Kuma can be reached (empty = normal DNS)"
    if [ -n "$KUMA_IP" ]; then
      [[ $KUMA_IP =~ $IPV4_RE ]] || die "invalid IP: $KUMA_IP"
      h=${KUMA_HEALTH:-$KUMA_BACKUP}; h=${h#*://}; KUMA_RES="${h%%/*}:443:$KUMA_IP"
    fi
  fi
  for u in "$SLACK_URL" "$KUMA_HEALTH" "$KUMA_BACKUP"; do
    [ -z "$u" ] || [[ $u == https://* ]] || die "URLs must start with https://."
  done
  cat > "$MON_ENV" <<EOF
# Monitoring – generated by setup.sh (used by scripts/monitor.sh, backup.sh, usage-report.sh). Empty = off.
SLACK_WEBHOOK_URL=$SLACK_URL
KUMA_PUSH_HEALTH=${KUMA_HEALTH%%\?*}
KUMA_PUSH_BACKUP=${KUMA_BACKUP%%\?*}
# Reach Uptime Kuma internally instead of via the public IP (no hairpin NAT): "host:443:ip"
KUMA_RESOLVE="$KUMA_RES"
# Budget warning in percent – one Slack message per threshold and budget time window
BUDGET_ALERT_THRESHOLDS="80 100"
# Report short windows (hours/days) only at these thresholds
BUDGET_ALERT_THRESHOLDS_SHORT="100"
BACKUP_DIR=/var/backups/kira
BACKUP_KEEP_DAYS=14
EOF
  unset SLACK_URL
  info "kira/env/monitoring.env created."
fi
if [ -d /etc/cron.d ]; then
  umask 022
  cat > /etc/cron.d/kira <<'EOF'
# KIRA – generated by /opt/kira/setup.sh (output in syslog: journalctl -t kira-…)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# every 5 minutes: container health to Uptime Kuma, budget warnings to Slack
*/5 * * * * root /opt/kira/scripts/monitor.sh 2>&1 | logger -t kira-monitor
# daily at 02:30: back up databases, files and /opt stacks
30 2 * * * root /opt/kira/scripts/backup.sh 2>&1 | logger -t kira-backup
# every 5 minutes: own agents (BUILDER_GROUP + model groups) from Keycloak – only active with builder.… in agents/groups.env
*/5 * * * * root python3 -I /opt/kira/scripts/builder-sync.py --quiet 2>&1 | logger -t kira-builders
# on the 1st of the month at 08:05: costs per user and key (previous month) to Slack
5 8 1 * * root /opt/kira/scripts/usage-report.sh 2>&1 | logger -t kira-usage
EOF
  if is_true PRIVACY_GUARD && is_true GUARD_SLACK; then
    cat >> /etc/cron.d/kira <<'EOF'
# Mondays at 08:10: privacy guard counts of the last week (no content) to Slack
10 8 * * 1 root /opt/kira/scripts/privacy-report.sh 2>&1 | logger -t kira-privacy
EOF
  fi
  umask 077
  info "/etc/cron.d/kira written."
  command -v cron >/dev/null || command -v crond >/dev/null \
    || warn "cron is not installed – monitoring and backup only run after: apt install cron"
else
  warn "/etc/cron.d is missing – create the cron entries from the README by hand."
fi

# ---------------------------------------------------------------- 11. Permissions
for d in "${STACK_DIRS[@]}"; do
  chmod 700 "$d/env"
  find "$d/env" -type f -exec chmod 600 {} +
done
chmod 644 "$KIRA/config/librechat.yaml" "$EGRESS_ENV" "$BIFROST_JSON" "$CADDY/config/Caddyfile"
chmod 700 "$KIRA/scripts"
chmod 755 "$KIRA/scripts"/*.sh "$KIRA/scripts"/*.py

# ---------------------------------------------------------------- 11b. Privacy guard: Bifrost image with the plugin
VERSIONS_BF=$BIFROST/env/versions.env
if is_true PRIVACY_GUARD; then
  section "Privacy guard (Bifrost with plugin)"
  BF_TAG=$(env_get "$VERSIONS_BF" BIFROST_TAG)
  PG_DIR=$BIFROST/plugins/privacy-guard
  [ -f "$PG_DIR/Dockerfile" ] || die "$PG_DIR is missing – copy it from the package."
  # image tag = Bifrost version + hash of the plugin sources: a new plugin or Bifrost version builds a new image
  PG_HASH=$(cd "$PG_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-10)
  GUARD_IMAGE="kira/bifrost-guard:${BF_TAG}-${PG_HASH}"
  if docker image inspect "$GUARD_IMAGE" >/dev/null 2>&1; then
    info "Image $GUARD_IMAGE exists."
  else
    info "Building $GUARD_IMAGE – Bifrost $BF_TAG with the privacy-guard plugin (takes 5–15 minutes) …"
    # the same base images as the official Bifrost build of this version (Go plugins need identical toolchains)
    UPSTREAM=$(curl -fsSL -m 30 "https://raw.githubusercontent.com/maximhq/bifrost/transports/$BF_TAG/transports/Dockerfile") \
      || die "Official Bifrost Dockerfile for $BF_TAG not reachable (GitHub) – check BIFROST_TAG in $VERSIONS_BF."
    FROMS=$(printf '%s\n' "$UPSTREAM" | sed -n 's/^[[:space:]]*FROM[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p')
    NODE_IMG=$(printf '%s\n' "$FROMS" | grep '^node:' | head -1 || true)
    GO_IMG=$(printf '%s\n' "$FROMS" | grep '^golang:' | head -1 || true)
    RT_IMG=$(printf '%s\n' "$FROMS" | grep '^alpine:' | tail -1 || true)
    [ -n "$NODE_IMG" ] && [ -n "$GO_IMG" ] && [ -n "$RT_IMG" ] \
      || die "Base images not found in the official Dockerfile of Bifrost $BF_TAG – the build has to be adapted (kira/PRIVACY-GUARD.md)."
    docker build --build-arg BIFROST_TAG="$BF_TAG" --build-arg NODE_IMAGE="$NODE_IMG" --build-arg GO_IMAGE="$GO_IMG" \
      --build-arg RUNTIME_IMAGE="$RT_IMG" -t "$GUARD_IMAGE" "$PG_DIR" \
      || die "Build of $GUARD_IMAGE failed – details above (kira/PRIVACY-GUARD.md, section Troubleshooting)."
    info "Image $GUARD_IMAGE built."
  fi
  env_set "$VERSIONS_BF" BIFROST_IMAGE "$GUARD_IMAGE"
else
  sed -i '/^BIFROST_IMAGE=/d' "$VERSIONS_BF" 2>/dev/null || true   # official image as before
fi

# ---------------------------------------------------------------- 12. Start
section "Start"
STACKS=(bifrost websearch)
is_true CODE_INTERPRETER && STACKS+=(codeinterpreter)
STACKS+=(kira)
is_true ONYX_ENABLED && STACKS+=(onyx)
STACKS+=(caddy)
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
groups_pending() {   # agents per group: plan differs from the last applied state
  local plan=$KIRA/config/agent-groups.json state=$KIRA/config/agent-groups.state.json
  if is_true AGENT_GROUPS; then
    ! cmp -s "$plan" "$state" || [ "$(env_get "$LC_ENV" OPENID_ROLE_SYNC_ENABLED)" != true ]
  else
    # also without a state yet: the role permissions (agents, "+") are set there
    if cmp -s "$plan" "$state"; then return 1; fi
  fi
}

info "Order: ${STACKS[*]}. Alternatively paste /opt/<stack>/docker-compose.yml into Portainer for each stack."
ask_yesno START "Pull and start (or update) the stacks now with docker compose?"
if [ "$START" = true ]; then
  for s in "${STACKS[@]}"; do
    if [ "$s" = codeinterpreter ]; then
      # built from source (no public images): only when the version changed or an image is missing
      CA=$CODEI/codeapi.sh
      stamp=$CODEI/env/built.version
      if [ "$(cat "$stamp" 2>/dev/null)" != "$CODE_VERSION" ] \
         || ! docker image inspect codeinterpreter-api codeinterpreter-sandbox-runner >/dev/null 2>&1; then
        info "--- codeinterpreter: building $CODE_VERSION (first build 30 minutes or more – it compiles the sandbox runtimes)"
        bash "$CA" build || die "build of the code interpreter failed – details above (codeinterpreter/README.md)."
        echo "$CODE_VERSION" > "$stamp"
      fi
      info "--- codeinterpreter: pulling images"
      bash "$CA" pull redis minio \
        || die "images of the code interpreter could not be pulled (REDIS_IMAGE/MINIO_IMAGE in $CODEI/env/versions.env)."
      info "--- codeinterpreter: starting"
      bash "$CA" up -d --no-build --remove-orphans || die "starting the code interpreter failed – bash $CA logs"
      continue
    fi
    f=/opt/$s/docker-compose.yml
    info "--- $s: pulling images"
    if [ "$s" = bifrost ] && is_true PRIVACY_GUARD; then
      docker compose -f "$f" pull db || die "images for $s could not be pulled – check the tag in /opt/$s/env/versions.env."
    else
      docker compose -f "$f" pull || die "images for $s could not be pulled – check the tag in /opt/$s/env/versions.env."
    fi
    info "--- $s: starting"
    docker compose -f "$f" up -d --remove-orphans || die "starting $s failed – docker compose -f $f logs"
  done
  # Configuration files change without the container being recreated – reload them explicitly
  if [ "$HASH_BIFROST_BEFORE" != "$HASH_BIFROST_AFTER" ] && running bifrost; then
    info "bifrost.json changed – restarting Bifrost."; docker restart bifrost >/dev/null
  fi
  if [ "$HASH_LC_BEFORE" != "$HASH_LC_AFTER" ] && running librechat; then
    info "librechat.yaml or branding changed – restarting LibreChat."; docker restart librechat >/dev/null
  fi
  if [ "$HASH_CADDY_BEFORE" != "$HASH_CADDY_AFTER" ] && running caddy; then
    info "Caddy configuration changed – reloading."
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null || warn "caddy reload failed – docker logs caddy"
  fi
  if ! is_true ONYX_ENABLED && running onyx-api; then
    info "Note: Onyx is off but still running – stop it with: docker compose -f /opt/onyx/docker-compose.yml down"
  fi
  if ! is_true CODE_INTERPRETER && running codeapi; then
    info "Note: the code interpreter is off but still running – stop it with: bash $CODEI/codeapi.sh down"
  fi
  if running office-mcp || running office-files; then
    info "Note: the office stack (download links) was replaced by the code interpreter – remove it with:"
    info "  docker compose -f /opt/office/docker-compose.yml down -v && docker network rm kira-office && rm -rf /opt/office"
  fi
  if groups_pending && running librechat; then
    bash "$KIRA/scripts/agent-groups.sh" --no-regenerate || warn "Agents per group not applied – run $KIRA/scripts/agent-groups.sh again."
  fi
  if has_builders && running librechat; then
    info "Builder groups (own agents):"
    python3 -I "$KIRA/scripts/builder-sync.py" || warn "Builder sync failed – details above; it runs again every 5 minutes."
  fi
  "$KIRA/scripts/self-test.sh" || warn "Self-test reported errors – details above, README section \"Troubleshooting\"."
else
  info "Not started. After starting (Portainer) check: $KIRA/scripts/self-test.sh"
  [ "$HASH_LC_BEFORE" != "$HASH_LC_AFTER" ] && running librechat && info "Note: librechat.yaml or branding changed – docker restart librechat"
  [ "$HASH_BIFROST_BEFORE" != "$HASH_BIFROST_AFTER" ] && running bifrost && info "Note: bifrost.json changed – docker restart bifrost"
  [ "$HASH_CADDY_BEFORE" != "$HASH_CADDY_AFTER" ] && running caddy && info "Note: Caddy changed – docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
  groups_pending && info "Note: agents per group not applied yet – after starting: bash $KIRA/scripts/agent-groups.sh"
fi

section "Next steps (README)"
info "1. Keycloak: in client $(env_get "$LC_ENV" OPENID_CLIENT_ID) allow the redirect URI https://$DOMAIN/oauth/openid/callback"
info "   and add https://$DOMAIN/login as post-logout redirect URI."
info "2. DNS: $DOMAIN${LD:+, $LD}$(is_true ONYX_ENABLED && printf ', %s' "$(setup_get ONYX_DOMAIN)") pointing to this server or the upstream proxy."
info "3. Log in at https://$DOMAIN – users with the Keycloak role admin become admins."
is_true AGENT_GROUPS && info "   Agents per group: in Keycloak add the mapper \"groups\" (full group path off) and set the default group (e.g. kira-users-default) under Realm settings → User registration → Default groups; admins = members of the ADMIN_GROUP (e.g. kira-admins) – no group, no login (README)."
is_true IMAGE_GENERATION && info "4. Create the image agent once: README, section \"Image agent\"."
is_true ONYX_ENABLED && info "5. Set up Onyx (admin account, LLM via Bifrost, API key, SharePoint): README, section \"Onyx\"."
is_true CODE_INTERPRETER && info "6. Code interpreter: in KIRA \"Erstelle eine Word-Datei mit …\" – the file appears in the chat (codeinterpreter/README.md)."
exit 0
