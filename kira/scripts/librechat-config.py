#!/usr/bin/env python3
# ============================================================================
# librechat-config.py – generates /opt/kira/config/librechat.yaml from
#   env/setup.env      switches (Onyx, user headers, images, speech, agent builder, ...)
#   env/librechat.env  only: is ONYX_API_KEY set?
#   agents/*.env/.md   agents (model specs), agents/groups.env (agents per Keycloak group)
# Called by setup.sh, scripts/agent-builder.sh and scripts/agent-groups.sh – manually:
#   python3 /opt/kira/scripts/librechat-config.py
# Python standard library only. Do not edit the generated YAML by hand – it is overwritten.
# ============================================================================
import base64
import json
import os
import re
import sys

KIRA_DIR = os.environ.get("KIRA_DIR", "/opt/kira")
CONFIG_VERSION = "1.3.19"          # matches LibreChat v0.8.9
ENDPOINT = "Bifrost"               # name of the custom endpoint (invisible to users)
# Claude models get prompt caching (top-level cache_control). Bifrost passes it on unchanged to OpenAI, which
# would reject the request – so models of other providers run on their own endpoints without it.
PROVIDER_LABELS = {"anthropic": "Anthropic", "openai": "OpenAI"}
BIFROST_JSON = os.environ.get("BIFROST_JSON", "/opt/bifrost/config/bifrost.json")
TITLE_MODEL = "anthropic/claude-haiku-5-5"
TITLE_ALIAS = "kira/title"                          # with the privacy guard (title_alias in bifrost.json)
# added to the instruction of agents with CODE=true (German, the agents answer in German)
CODE_PROMPT = ("Code-Ausführung und Dokumente: Für Berechnungen, Auswertungen hochgeladener Dateien und Diagramme "
               "nutze die Code-Ausführung (Python, ohne Internet). Möchte der Nutzer ein Dokument, erstelle die Datei "
               "mit Python und speichere sie in /mnt/data – sie erscheint dann im Chat mit Vorschau und Download: "
               "Word mit python-docx (.docx), Excel mit openpyxl (.xlsx, mit Formeln und Formatierung), PowerPoint "
               "mit python-pptx (.pptx), PDF mit reportlab, CSV mit pandas. Wähle einen sprechenden deutschen "
               "Dateinamen (z. B. Protokoll_2026-11-27.docx), deutsche Datums- und Zahlenformate und eine saubere "
               "Gestaltung (Überschriften, Tabellen mit Kopfzeile). Hat der Nutzer eine Vorlage hochgeladen, nutze "
               "sie als Grundlage (Word z. B. mit docxtpl). Fasse danach kurz zusammen, was die Datei enthält.")
# image agent (stored agent): own endpoint, so that builders (own agents) can use it without getting "Bifrost"
IMAGE_ENDPOINT = "Bild-Agent"
IMAGE_AGENT_MODEL = "anthropic/claude-haiku-5-5"   # only writes the image description
# agent builder for builders: only "Temperatur" and "Denkaufwand" (reasoning_effort) stay adjustable – all
# other model parameters are hidden (and not sent). LibreChat names: maxTokens/topP/… are mapped to the interface
# keys max_tokens/top_p/…
BUILDER_DROP_PARAMS = ["maxContextTokens", "maxTokens", "topP", "frequencyPenalty", "presencePenalty", "stop",
                       "resendFiles", "imageDetail", "fileTokenLimit", "reasoning_summary",
                       "reasoning_mode", "reasoning_context", "verbosity", "useResponsesApi", "web_search",
                       "disableStreaming"]
# price per million tokens as in LibreChat v0.8.9 (only for LibreChat's own usage records – costs are counted in
# Bifrost); needed because tokenConfig (context limit for own agents) requires rates
# (OpenAI: list prices as of 11/2026 from the press, not checked against OpenAI's price page)
LIBRECHAT_RATES = {"claude-haiku-5-5": (0.1, 0.5), "claude-sonnet-5-5": (2, 10), "claude-opus-5-5": (4, 20),
                   "gpt-6-luna": (0.1, 0.5), "gpt-6.1-terra": (1, 5), "gpt-6.1-sol": (2, 10), "gpt-6-astra": (10, 50)}
BUILDER_PRIORITY = 137              # config priority of the per-user builder profiles (marks them as KIRA-managed)
# File uploads with UPLOAD_OFFICE_ONLY: PDF, Office, OpenDocument, text (incl. CSV, Markdown, code), images
OFFICE_MIME_TYPES = [
    "^application/pdf$",
    "^application/msword$",
    "^application/vnd\\.ms-excel$",
    "^application/vnd\\.ms-powerpoint$",
    "^application/vnd\\.openxmlformats-officedocument\\..+$",
    "^application/vnd\\.oasis\\.opendocument\\..+$",
    "^application/rtf$",
    "^text/.+$",
    "^application/(json|xml|x-yaml|yaml|javascript|x-javascript|x-sh|x-python)$",
    "^image/(jpeg|png|gif|webp|heic|heif)$",
]
TTS_VOICES = ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]  # OpenAI voices


def fail(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def read_env(path, required=True):
    """Read a KEY=VALUE file (comments #, values optionally in "…" or '…')."""
    values = {}
    if not os.path.exists(path):
        if required:
            fail(f"{path} is missing – run setup.sh first.")
        return values
    with open(path, encoding="utf-8") as fh:
        for no, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                fail(f"{path}, line {no}: expected KEY=VALUE, found: {line[:60]}")
            key, value = line.split("=", 1)
            key, value = key.strip(), value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key] = value
    return values


def hours(value, name, where, lo, hi, default=None):
    """Duration Nh/Nd from setup.env in hours (empty = default)."""
    v = (value or "").strip().lower()
    if not v:
        return default
    m = re.fullmatch(r"(\d+)([hd])", v)
    if not m:
        fail(f"{where}: {name}={value!r} – expected e.g. 24h or 90d.")
    n = int(m.group(1)) * (24 if m.group(2) == "d" else 1)
    if not lo <= n <= hi:
        fail(f"{where}: {name}={value!r} – allowed {lo}h to {hi // 24}d.")
    return n


# interface field → LibreChat permission type (librechat-data-provider PERMISSION_TYPE_INTERFACE_FIELDS)
INTERFACE_PERMISSIONS = {"prompts": "PROMPTS", "agents": "AGENTS", "bookmarks": "BOOKMARKS", "memories": "MEMORIES",
                         "multiConvo": "MULTI_CONVO", "temporaryChat": "TEMPORARY_CHAT", "runCode": "RUN_CODE",
                         "webSearch": "WEB_SEARCH", "fileSearch": "FILE_SEARCH", "fileCitations": "FILE_CITATIONS",
                         "peoplePicker": "PEOPLE_PICKER", "marketplace": "MARKETPLACE", "mcpServers": "MCP_SERVERS",
                         "remoteAgents": "REMOTE_AGENTS", "skills": "SKILLS", "sharedLinks": "SHARED_LINKS"}
PERMISSION_KEYS = {"use": "USE", "create": "CREATE", "share": "SHARE", "public": "SHARE_PUBLIC",
                   "users": "VIEW_USERS", "groups": "VIEW_GROUPS", "roles": "VIEW_ROLES"}


def role_permissions(interface):
    """Permissions as LibreChat derives them from the interface settings (true/false or {use, create, …})."""
    out = {}
    for field, ptype in INTERFACE_PERMISSIONS.items():
        val = interface.get(field)
        if isinstance(val, bool):
            out[ptype] = {"USE": val}
        elif isinstance(val, dict):
            perms = {PERMISSION_KEYS[k]: v for k, v in val.items() if k in PERMISSION_KEYS and isinstance(v, bool)}
            if perms:
                out[ptype] = perms
    return out


def german_duration(h):
    """Hours in German after "nach": 24 → "einem Tag", 2160 → "90 Tagen", 12 → "12 Stunden"."""
    if h % 24 == 0:
        d = h // 24
        return "einem Tag" if d == 1 else f"{d} Tagen"
    return "einer Stunde" if h == 1 else f"{h} Stunden"


def fill_terms(lines, s, chat_retention, temp_retention):
    """Placeholders in config/terms-of-use.md, filled from setup.env – the text always matches the configuration."""
    where = "config/terms-of-use.md"
    log_h = hours(s.get("BIFROST_LOG_RETENTION"), "BIFROST_LOG_RETENTION", "env/setup.env", 24, 3650 * 24, 90 * 24)
    if log_h % 24:
        fail(f"env/setup.env: BIFROST_LOG_RETENTION={s.get('BIFROST_LOG_RETENTION')!r} – whole days only, e.g. 90d.")
    log_days = log_h // 24
    limit = number(s.get("MESSAGE_LIMIT"), "MESSAGE_LIMIT", "env/setup.env", 0, 1000, 20)
    values = {
        "CHAT_RETENTION": f"nach {german_duration(chat_retention)} automatisch gelöscht (gerechnet ab Beginn des Chats)"
        if chat_retention else "nicht automatisch gelöscht",
        "TEMP_CHAT_RETENTION": german_duration(temp_retention),
        "LOG_RETENTION": "einen Tag" if log_days == 1 else f"{log_days} Tage",
        "USER_IN_LOGS": "mit deinem Namen und deiner E-Mail-Adresse"
        if is_yes(s.get("SEND_USER_HEADERS"), "SEND_USER_HEADERS", "env/setup.env")
        else "ohne deinen Namen oder deine E-Mail-Adresse",
        "LOG_CONTENT": "Dabei werden auch deine Fragen und KIRAs Antworten mitprotokolliert."
        if is_yes(s.get("LOG_CHAT_CONTENT"), "LOG_CHAT_CONTENT", "env/setup.env")
        else "Die Inhalte deiner Fragen und der Antworten stehen nicht in diesen Protokollen.",
        "MESSAGE_LIMIT": f"Pro Minute kannst du höchstens {limit} Nachrichten senden, damit der Dienst für alle läuft."
        if limit else "",
    }
    out = []
    for line in lines:
        for key, val in values.items():
            line = line.replace("{{" + key + "}}", val)
        left = re.findall(r"\{\{[A-Z_]+\}\}", line)
        if left:
            fail(f"{where}: unknown placeholder {left[0]} – known: " + ", ".join("{{%s}}" % k for k in values))
        out.append(re.sub(r" +$", "", re.sub(r"  +", " ", line)) if line.strip() else line)
    return out


def number(value, name, where, lo, hi, default):
    v = (value or "").strip()
    if not v:
        return default
    if not v.isdigit() or not lo <= int(v) <= hi:
        fail(f"{where}: {name}={value!r} – allowed is a number from {lo} to {hi}.")
    return int(v)


def is_yes(value, name, where):
    v = (value or "").strip().lower()
    if v in ("ja", "j", "yes", "y", "true", "1"):
        return True
    if v in ("nein", "n", "no", "false", "0", ""):
        return False
    fail(f"{where}: {name}={value!r} – allowed are true/false.")


# ---------------------------------------------------------------- YAML output
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


def scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if value is None:
        return "null"
    return json.dumps(str(value), ensure_ascii=False)   # JSON string = valid YAML string in "…"


def emit(value, indent=0):
    pad = " " * indent
    out = []
    if isinstance(value, dict):
        if not value:
            return [pad + "{}"]
        for key, val in value.items():
            k = key if KEY_RE.match(key) else json.dumps(key)
            if isinstance(val, str) and "\n" in val:
                out.append(f"{pad}{k}: |-")
                out.extend((pad + "  " + line) if line else "" for line in val.split("\n"))
            elif isinstance(val, (dict, list)) and val:
                out.append(f"{pad}{k}:")
                out.extend(emit(val, indent + 2))
            elif isinstance(val, dict):
                out.append(f"{pad}{k}: {{}}")
            elif isinstance(val, list):
                out.append(f"{pad}{k}: []")
            else:
                out.append(f"{pad}{k}: {scalar(val)}")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, (dict, list)) and item:
                sub = emit(item, indent + 2)
                out.append(pad + "- " + sub[0].lstrip())
                out.extend(sub[1:])
            else:
                out.append(f"{pad}- {scalar(item)}")
    else:
        out.append(pad + scalar(value))
    return out


# ---------------------------------------------------------------- Agents
ICON_TYPES = {".webp": "image/webp", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
              ".svg": "image/svg+xml"}
ICON_MAX_BYTES = 256 * 1024


def icon_data_uri(agents_dir, value, where):
    """ICON=<file in agents/> -> data: URI for the model spec (shown in the agent menu)."""
    name = os.path.basename(value)
    ext = os.path.splitext(name)[1].lower()
    if name != value or ext not in ICON_TYPES:
        fail(f"{where}: ICON={value!r} – file name in agents/ with {', '.join(ICON_TYPES)}.")
    path = os.path.join(agents_dir, name)
    if not os.path.isfile(path):
        fail(f"{where}: ICON={value!r} – file not found in agents/.")
    data = open(path, "rb").read()
    if len(data) > ICON_MAX_BYTES:
        fail(f"{where}: ICON={value!r} is larger than {ICON_MAX_BYTES // 1024} KB.")
    return f"data:{ICON_TYPES[ext]};base64,{base64.b64encode(data).decode()}"


NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")


def load_agents(setup, onyx_ready, compact_at=None):
    agents_dir = os.path.join(KIRA_DIR, "agents")
    files = sorted(f for f in os.listdir(agents_dir) if f.endswith(".env") and f != "groups.env")
    specs, models, notes, names = [], [], [], set()
    image_on = setup["IMAGE_GENERATION"]
    for order, fname in enumerate(files, 1):
        path = os.path.join(agents_dir, fname)
        where = f"agents/{fname}"
        a = read_env(path)
        if not is_yes(a.get("ENABLED", "true"), "ENABLED", where):
            notes.append(f"{where}: ENABLED=false – hidden")
            continue
        name = a.get("NAME", "")
        if not NAME_RE.match(name):
            fail(f"{where}: NAME={name!r} – only a-z, 0-9 and - (max. 41 characters).")
        if name in names:
            fail(f"{where}: NAME={name!r} is a duplicate.")
        names.add(name)
        title = a.get("TITLE") or fail(f"{where}: TITLE is missing.")
        prompt_path = path[:-4] + ".md"
        prompt = ""
        if os.path.exists(prompt_path):
            with open(prompt_path, encoding="utf-8") as fh:
                prompt = fh.read().replace("\r\n", "\n").replace("\t", "    ").strip()
        is_image = is_yes(a.get("IMAGES"), "IMAGES", where)
        is_intranet = is_yes(a.get("INTRANET"), "INTRANET", where)
        # code interpreter (also documents): only if switched on in setup.sh, otherwise silently without
        with_code = is_yes(a.get("CODE", "false"), "CODE", where) and setup.get("_code_ready", False)
        if with_code:
            prompt = (prompt + "\n\n" if prompt else "") + CODE_PROMPT

        spec = {"name": name, "label": title}
        if a.get("DESCRIPTION"):
            spec["description"] = a["DESCRIPTION"]
        spec["order"] = order
        if a.get("ICON"):
            spec["iconURL"] = icon_data_uri(agents_dir, a["ICON"], where)
        if is_yes(a.get("DEFAULT"), "DEFAULT", where):
            spec["default"] = True

        if is_image:
            if not image_on:
                notes.append(f"{where}: skipped – image generation is off (IMAGE_GENERATION=false)")
                continue
            agent_id = a.get("AGENT_ID", "")
            if not agent_id:
                notes.append(f"{where}: skipped – AGENT_ID is missing (README, section \"Image agent\")")
                continue
            if not re.match(r"^agent_[A-Za-z0-9_-]+$", agent_id):
                fail(f"{where}: AGENT_ID={agent_id!r} – expected agent_… from LibreChat.")
            spec["preset"] = {"agent_id": agent_id}
            spec["hideBadgeRow"] = True
            setup["_image_agent_id"] = agent_id
            specs.append(spec)
            continue

        if is_intranet and not onyx_ready:
            notes.append(f"{where}: skipped – Onyx is off or ONYX_API_KEY is missing in env/librechat.env")
            continue

        model = a.get("MODEL", "")
        if not MODEL_RE.match(model):
            fail(f"{where}: MODEL={model!r} – Bifrost model ID with provider, e.g. anthropic/claude-sonnet-5-5.")
        check_allowed(model, where)
        if model not in models:
            models.append(model)
        preset = {"endpoint": fixed_endpoint_name(model), "model": model}
        if a.get("TEMPERATURE"):
            try:
                temp = float(a["TEMPERATURE"].replace(",", "."))
            except ValueError:
                fail(f"{where}: TEMPERATURE={a['TEMPERATURE']!r} is not a number.")
            top = 1 if provider_of(model) == "anthropic" else 2      # Anthropic accepts at most 1
            if not 0 <= temp <= top:
                fail(f"{where}: TEMPERATURE must be between 0 and {top} for {model}.")
            preset["temperature"] = temp
        if prompt:
            preset["promptPrefix"] = prompt
        if compact_at:
            # context limit: above it LibreChat summarises older parts (summarization) instead of sending everything
            preset["maxContextTokens"] = compact_at
        spec["preset"] = preset
        # tools fixed per agent; hideBadgeRow: users cannot toggle them
        spec["webSearch"] = is_yes(a.get("WEB_SEARCH"), "WEB_SEARCH", where)
        spec["fileSearch"] = is_yes(a.get("FILE_SEARCH"), "FILE_SEARCH", where)
        spec["executeCode"] = with_code
        spec["mcpServers"] = ["intranet"] if is_intranet else []
        spec["hideBadgeRow"] = True
        specs.append(spec)

    if not specs:
        fail("no active agent in agents/ – at least one is required.")
    defaults = [s["name"] for s in specs if s.get("default")]
    if len(defaults) > 1:
        fail(f"DEFAULT=true on several agents: {', '.join(defaults)} – only one is allowed.")
    if not defaults:
        specs[0]["default"] = True
    return specs, models, notes


# ---------------------------------------------------------------- Agents per Keycloak group
GROUP_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
GROUPS_FILE = "groups.env"
MODEL_RE = re.compile(r"^[a-z0-9-]+/[A-Za-z0-9._:-]+$")


def all_agent_names(agents_dir):
    names = set()
    for fname in os.listdir(agents_dir):
        if fname.endswith(".env") and fname != GROUPS_FILE:
            name = read_env(os.path.join(agents_dir, fname)).get("NAME", "")
            if name:
                names.add(name)
    return names


def load_groups(specs, notes):
    """Read agents/groups.env: visible agents (model specs) per group – plan for agent-groups.js."""
    agents_dir = os.path.join(KIRA_DIR, "agents")
    path = os.path.join(agents_dir, GROUPS_FILE)
    where = f"agents/{GROUPS_FILE}"
    if not os.path.exists(path):
        fail(f"AGENT_GROUPS=true, but {where} is missing.")
    raw = read_env(path)
    admin_group = raw.pop("ADMIN_GROUP", "")
    builder_group = raw.pop("BUILDER_GROUP", "")
    if not GROUP_RE.match(admin_group):
        fail(f"{where}: ADMIN_GROUP={admin_group!r} – name of the admins' Keycloak group (e.g. kira-admins).")
    known = all_agent_names(agents_dir)
    active = {sp["name"]: sp for sp in specs}
    groups, order, seen, size = {}, [], set(), {}
    builder_raw = {k: raw.pop(k) for k in list(raw) if k.lower().startswith("builder.")}
    for group, value in raw.items():
        if not GROUP_RE.match(group):
            fail(f"{where}: group name {group!r} – allowed are letters, digits, . _ - (max. 64 characters).")
        if group.lower() in ("admin", "user", "standard"):
            fail(f"{where}: group name {group!r} is reserved.")
        if group.lower() in seen:
            fail(f"{where}: group {group!r} is a duplicate (case-insensitive).")
        seen.add(group.lower())
        wanted = [x.strip() for x in value.split(",") if x.strip()]
        if not wanted:
            fail(f"{where}: group {group!r} has no agents.")
        for name in wanted:
            if name not in known:
                fail(f"{where}: group {group!r} – agent {name!r} does not exist (NAME from the agent files).")
        visible = [sp for sp in specs if sp["name"] in wanted]   # same order as in the agent menu
        missing = [n for n in wanted if n not in active]
        if missing:
            notes.append(f"{where}: {group} – not active and therefore not visible: {', '.join(missing)}")
        if not visible:
            fail(f"{where}: group {group!r} – none of its agents is active.")
        lst = []
        for sp in visible:
            item = json.loads(json.dumps(sp))
            item.pop("default", None)
            lst.append(item)
        default_name = next((sp["name"] for sp in visible if sp.get("default")), visible[0]["name"])
        for item in lst:
            if item["name"] == default_name:
                item["default"] = True
        groups[group] = lst
        size[group] = len(set(wanted))
        order.append(group)
    if not groups:
        fail(f"{where}: no group defined.")
    if admin_group.lower() in seen:
        fail(f"{where}: ADMIN_GROUP={admin_group!r} must not also be listed as a group with agents.")
    # users in several groups get the group with the most agents (tie: order in the file)
    priority = sorted(order, key=lambda g: (-size[g], order.index(g)))
    # own agents: BUILDER_GROUP = may build (yes/no), builder.<model group>=<models> = which models
    if builder_raw and not builder_group:
        fail(f"{where}: builder.… lines need BUILDER_GROUP=<Keycloak group of the users who may build agents> "
             "(e.g. kira-builder).")
    if builder_group:
        if not builder_raw:
            fail(f"{where}: BUILDER_GROUP={builder_group!r} without builder.<model group>=… lines – nobody would get "
                 "a model.")
        if not GROUP_RE.match(builder_group):
            fail(f"{where}: BUILDER_GROUP={builder_group!r} – allowed are letters, digits, . _ - (max. 64 characters).")
        if builder_group.lower() in seen or builder_group.lower() == admin_group.lower():
            fail(f"{where}: BUILDER_GROUP={builder_group!r} must be a group of its own (not an agent group or "
                 "ADMIN_GROUP).")
    builders = {}
    for key, value in builder_raw.items():
        group = key.split(".", 1)[1]
        if not GROUP_RE.match(group):
            fail(f"{where}: model group name {group!r} – allowed are letters, digits, . _ - (max. 64 characters).")
        if group.lower() in seen or group.lower() in (admin_group.lower(), builder_group.lower()):
            fail(f"{where}: model group {group!r} must be a group of its own (not an agent group, ADMIN_GROUP or "
                 "BUILDER_GROUP).")
        if group.lower() in (b.lower() for b in builders):
            fail(f"{where}: model group {group!r} is a duplicate (case-insensitive).")
        wanted = []
        for model in (x.strip() for x in value.split(",")):
            if not model:
                continue
            if not MODEL_RE.match(model):
                fail(f"{where}: model group {group!r} – model {model!r}: Bifrost model ID with provider, "
                     "e.g. anthropic/claude-sonnet-5-5.")
            check_allowed(model, f"{where}: model group {group!r}")
            if model not in wanted:
                wanted.append(model)
        if not wanted:
            fail(f"{where}: model group {group!r} has no models.")
        # in the builder: "Anbieter" = provider (Anthropic, OpenAI, …), below it the models this user may use
        # (builder-sync.py narrows the model list per user to the models of their model groups)
        builders[group] = {"models": wanted}
    # one endpoint per provider with all builder models of that provider (order as in the file)
    builder_endpoints = {}
    for b in builders.values():
        for model in b["models"]:
            mods = builder_endpoints.setdefault(builder_endpoint_name(model), [])
            if model not in mods:
                mods.append(model)
    # without one of these groups (or ADMIN_GROUP) in the token: no login, and the role USER sees no agent
    return {"enabled": True, "priority": priority, "admin_group": admin_group, "builder_group": builder_group,
            "roles": groups, "endpoint": ENDPOINT, "builders": builders, "builder_endpoints": builder_endpoints}


def provider_of(model):
    return model.split("/", 1)[0]


def short_model(model):
    """anthropic/claude-sonnet-5-5 → Sonnet, openai/gpt-6.1-terra → Terra; other IDs without provider."""
    m = model.split("/", 1)[1]
    hit = re.match(r"^claude-([a-z]+)(-[0-9-]+)?$", m) or re.match(r"^gpt-[0-9.]+-([a-z]+)$", m)
    return hit.group(1).capitalize() if hit else m


def builder_endpoint_name(model):
    """Name shown as "Anbieter" in the agent builder: the provider, e.g. "Anthropic" or "OpenAI"."""
    prov = provider_of(model)
    return PROVIDER_LABELS.get(prov, prov.capitalize()).replace(".", "-")


def fixed_endpoint_name(model):
    """Endpoint of a fixed agent: "Bifrost" for Claude, "Bifrost OpenAI" etc. for other providers (no cache_control)."""
    prov = provider_of(model)
    return ENDPOINT if prov == "anthropic" else f"{ENDPOINT} {PROVIDER_LABELS.get(prov, prov.capitalize())}"


_ALLOWED = None


def check_allowed(model, where):
    """Model must be allowed for the Bifrost key of LibreChat (vk-librechat) – catches typos like gpt-6.1-luna."""
    global _ALLOWED
    if _ALLOWED is None:
        _ALLOWED = set()
        try:
            with open(BIFROST_JSON, encoding="utf-8") as fh:
                gov = json.load(fh).get("governance", {})
            for vk in gov.get("virtual_keys", []):
                if "librechat" in f"{vk.get('id', '')} {vk.get('name', '')}".lower():
                    for pc in vk.get("provider_configs", []):
                        for m in pc.get("allowed_models", []):
                            _ALLOWED.add(f"{pc.get('provider')}/{m}")
        except (OSError, ValueError):
            pass            # no bifrost.json (yet): no check
    if _ALLOWED and model not in _ALLOWED:
        fail(f"{where}: model {model!r} is not allowed for the Bifrost key vk-librechat – allowed: "
             f"{', '.join(sorted(_ALLOWED))}")


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


# ---------------------------------------------------------------- Configuration
def main():
    s = read_env(os.path.join(KIRA_DIR, "env", "setup.env"))
    lc = read_env(os.path.join(KIRA_DIR, "env", "librechat.env"))
    where = "env/setup.env"
    setup = {
        "ONYX_ENABLED": is_yes(s.get("ONYX_ENABLED"), "ONYX_ENABLED", where),
        "CODE_INTERPRETER": is_yes(s.get("CODE_INTERPRETER", "false"), "CODE_INTERPRETER", where),
        "SEND_USER_HEADERS": is_yes(s.get("SEND_USER_HEADERS"), "SEND_USER_HEADERS", where),
        "IMAGE_GENERATION": is_yes(s.get("IMAGE_GENERATION"), "IMAGE_GENERATION", where),
        "SPEECH": is_yes(s.get("SPEECH"), "SPEECH", where),
        "AGENT_BUILDER": is_yes(s.get("AGENT_BUILDER", "false"), "AGENT_BUILDER", where),
        "TERMS_ENABLED": is_yes(s.get("TERMS_ENABLED", "false"), "TERMS_ENABLED", where),
        "CONTEXT_USAGE": is_yes(s.get("CONTEXT_USAGE", "false"), "CONTEXT_USAGE", where),
        "AGENT_GROUPS": is_yes(s.get("AGENT_GROUPS", "false"), "AGENT_GROUPS", where),
        "UPLOAD_OFFICE_ONLY": is_yes(s.get("UPLOAD_OFFICE_ONLY", "false"), "UPLOAD_OFFICE_ONLY", where),
        "PRIVACY_GUARD": is_yes(s.get("PRIVACY_GUARD", "false"), "PRIVACY_GUARD", where),
    }
    chat_retention = hours(s.get("CHAT_RETENTION"), "CHAT_RETENTION", where, 24, 8760)
    temp_retention = hours(s.get("TEMP_CHAT_RETENTION"), "TEMP_CHAT_RETENTION", where, 1, 8760, 24)
    upload_mb = number(s.get("UPLOAD_MAX_MB"), "UPLOAD_MAX_MB", where, 1, 50, 20)
    upload_files = number(s.get("UPLOAD_MAX_FILES"), "UPLOAD_MAX_FILES", where, 1, 50, 10)
    url_re = re.compile(r"^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^\s\"$`\\]*)?$")
    privacy_url = s.get("PRIVACY_URL", "").strip()
    if privacy_url and not url_re.match(privacy_url):
        fail(f"{where}: PRIVACY_URL={privacy_url!r} is not a valid https address.")
    onyx_ready = setup["ONYX_ENABLED"] and bool(lc.get("ONYX_API_KEY"))
    setup["_code_ready"] = setup["CODE_INTERPRETER"] and bool(lc.get("LIBRECHAT_CODE_BASEURL"))
    compact_at = number(s.get("COMPACT_AT"), "COMPACT_AT", where, 0, 1000000, 100000)
    if 0 < compact_at < 20000:
        fail(f"{where}: COMPACT_AT={compact_at} – 0 or at least 20000.")
    specs, models, notes = load_agents(setup, onyx_ready, compact_at)
    if TITLE_MODEL not in models:
        models.append(TITLE_MODEL)
    builder = setup["AGENT_BUILDER"]

    endpoint = {
        "name": ENDPOINT,
        "apiKey": "${BIFROST_API_KEY}",
        "baseURL": "http://bifrost:8080/v1",
        "models": {"default": [m for m in models if provider_of(m) == "anthropic"], "fetch": False},
        "titleConvo": True,
        # privacy guard: titles ask for an alias – the guard sends them to TITLE_MODEL or, with personal data, to the
        # local model, and adds no notice to titles (kira/PRIVACY-GUARD.md)
        "titleModel": TITLE_ALIAS if setup["PRIVACY_GUARD"] else TITLE_MODEL,
        "modelDisplayLabel": "KIRA",
        # prompt caching for Claude: top-level cache_control = automatic caching at Anthropic (Bifrost passes it
        # through). Repeated parts (history, search results) then cost about 1/10. Only on Claude endpoints.
        "addParams": {"cache_control": {"type": "ephemeral"}},
    }
    if setup["SEND_USER_HEADERS"]:
        # only end up in the Bifrost logs (logging_headers), not at Anthropic/OpenAI
        endpoint["headers"] = {
            "X-LibreChat-User-Email": "{{LIBRECHAT_USER_EMAIL}}",
            "X-LibreChat-User-Name": "{{LIBRECHAT_USER_NAME}}",
            "X-LibreChat-User-Id": "{{LIBRECHAT_USER_ID}}",
        }

    plan = load_groups(specs, notes) if setup["AGENT_GROUPS"] else {"enabled": False}
    image_agent_id = setup.get("_image_agent_id")
    custom = [endpoint]

    def variant(name, ep_models):
        """Copy of the Bifrost endpoint with its own model list; cache_control only if all models are Claude."""
        ep = json.loads(json.dumps(endpoint))
        ep["name"] = name
        ep["models"] = {"default": ep_models, "fetch": False}
        if any(provider_of(m) != "anthropic" for m in ep_models):
            ep.pop("addParams", None)
        return ep

    # fixed agents of other providers (e.g. MODEL=openai/gpt-6.1-sol): one endpoint per provider
    for prov in sorted({provider_of(m) for m in models} - {"anthropic"}):
        ep_models = [m for m in models if provider_of(m) == prov]
        custom.append(variant(fixed_endpoint_name(ep_models[0]), ep_models))
    extra_endpoints = []          # (name, models) – image agent and builder providers
    if setup["IMAGE_GENERATION"]:
        extra_endpoints.append((IMAGE_ENDPOINT, [IMAGE_AGENT_MODEL]))
    for name, mods in (plan.get("builder_endpoints") or {}).items():
        extra_endpoints.append((name, mods))
    for name, ep_models in extra_endpoints:
        ep = variant(name, ep_models)
        ep["dropParams"] = BUILDER_DROP_PARAMS
        if compact_at:
            # the hidden "Max. Kontext-Token": own agents summarise long chats from COMPACT_AT like the fixed agents
            ep["tokenConfig"] = {}
            for mod in ep_models:
                prompt, completion = LIBRECHAT_RATES.get(mod.split("/", 1)[1], (0, 0))
                ep["tokenConfig"][mod] = {"prompt": prompt, "completion": completion, "context": compact_at}
        custom.append(ep)
    agents_endpoint = {"capabilities": ["file_search", "web_search", "artifacts", "tools", "context"]
                       + (["execute_code"] if setup.get("_code_ready") else [])}
    if not builder:
        # agent builder only for builders (per-user profile from scripts/builder-sync.py) – hidden for everyone else
        agents_endpoint["disableBuilder"] = True
        if image_agent_id:
            # stored agents only on the image agent's endpoint; builders get their providers per user
            agents_endpoint["allowedProviders"] = [IMAGE_ENDPOINT]

    cfg = {
        "version": CONFIG_VERSION,
        # tool library of the agent builder (LibreChat loads it once for everyone, it cannot be set per role):
        # only the image tool (image agent; builders may add it to their own agents too) – no Google, Wolfram,
        # Tavily, Flux … "kira-no-tools" matches no tool, so the list stays empty without image generation.
        "includedTools": ["image_gen_oai"] if setup["IMAGE_GENERATION"] else ["kira-no-tools"],
        "cache": True,
        "interface": {
            "customWelcome": "Willkommen bei KIRA – wie kann ich helfen?",
            # agents (model specs) only, no raw models – in agent builder mode everything is visible temporarily
            "modelSelect": builder,
            "parameters": False,
            "presets": False,
            "prompts": {"use": False, "create": False, "share": False, "public": False},
            # bookmarks = labels for chats (no model involvement, no costs)
            "bookmarks": True,
            # multiConvo ("+" next to the agent, two answers side by side): only for admins – set per role by
            # agent-groups.js (an entry here would also switch it off for ADMIN)
            # agents (use/create/share): set per role by agent-groups.js – an entry here would be applied to
            # ADMIN too on every start of LibreChat (admins could then no longer build agents)
            "marketplace": {"use": False},
            "peoplePicker": {"users": builder, "groups": builder, "roles": builder},
            "mcpServers": {"use": True, "create": False, "share": False, "public": False},
            "remoteAgents": {"use": False, "create": False, "share": False, "public": False},
            "webSearch": True,
            "fileSearch": True,
            "fileCitations": True,
            # code interpreter (stack codeinterpreter, setup.sh): "Run Code" on code blocks and execution for agents
            "runCode": bool(setup.get("_code_ready")),
            "memories": False,
            "feedback": False,
            "mascot": False,
            # links like …/c/new?prompt=…&submit=true only fill in the prompt, the user still has to send it
            # (a crafted link in an e-mail must not run a request in the user's name)
            "autoSubmitFromUrl": False,
            # no commit/build date in /api/config (readable without login – no version hints for attackers)
            "buildInfo": False,
            "analyticsConsent": False,
            # "context window" panel (token usage, "compress context") – off = hidden for everyone
            "contextUsage": setup["CONTEXT_USAGE"],
            "temporaryChat": True,
            "temporaryChatRetention": temp_retention,
        },
        "registration": {"socialLogins": ["openid"]},
        "memory": {"disabled": True},
        # summarising long chats (also the "compress context" button) with the inexpensive Haiku via Bifrost;
        # kicks in as soon as a chat exceeds the context limit (COMPACT_AT or the model limit)
        "summarization": {"enabled": True, "provider": ENDPOINT, "model": TITLE_MODEL,
                          "retainRecent": {"turns": 2}},
        "fileConfig": {"serverFileSizeLimit": upload_mb},
        "endpoints": {
            "agents": agents_endpoint,
            "custom": custom,
        },
        "webSearch": {
            "searchProvider": "searxng",
            "searxngInstanceUrl": "${SEARXNG_INSTANCE_URL}",
            "scraperProvider": "firecrawl",
            "firecrawlApiKey": "${FIRECRAWL_API_KEY}",
            "firecrawlApiUrl": "${FIRECRAWL_API_URL}",
            "rerankerType": "none",
            "searxngSearchOptions": {"engines": ["google", "bing", "brave", "startpage", "mojeek"], "language": "de"},
            # internal services are otherwise blocked as private destinations (SSRF protection)
            "allowedAddresses": ["searxng:8080", "firecrawl:3002"],
        },
        "modelSpecs": {"enforce": not builder, "prioritize": True, "list": specs},
    }

    # file uploads: size and count for all agents (default + agents, because agents have their own defaults)
    limits = {"fileLimit": upload_files, "fileSizeLimit": upload_mb, "totalSizeLimit": upload_mb * upload_files}
    if setup["UPLOAD_OFFICE_ONLY"]:
        limits["supportedMimeTypes"] = OFFICE_MIME_TYPES
    cfg["fileConfig"]["endpoints"] = {"default": dict(limits), "agents": dict(limits)}

    # retention: delete all chats (incl. files) CHAT_RETENTION after the start of the chat
    if chat_retention:
        cfg["interface"]["retentionMode"] = "all"
        cfg["interface"]["generalChatRetention"] = chat_retention
        # also allows deleting files in the document search (one LibreChat instance, no replicas)
        cfg["fileConfig"]["retainedFileCleanup"] = True

    if privacy_url:
        cfg["interface"]["privacyPolicy"] = {"externalUrl": privacy_url, "openNewTab": True}

    if setup["TERMS_ENABLED"]:
        terms_file = os.path.join(KIRA_DIR, "config", "terms-of-use.md")
        if not os.path.exists(terms_file):
            fail("TERMS_ENABLED=true, but config/terms-of-use.md is missing – setup.sh creates it from the template.")
        with open(terms_file, encoding="utf-8") as fh:
            lines = [ln.rstrip().replace("\t", "    ") for ln in fh.read().replace("\r", "").split("\n")]
        while lines and not lines[-1]:
            lines.pop()
        title = "Nutzungsbedingungen für KIRA"   # shown to users (German)
        if lines and lines[0].startswith("# "):
            title = lines.pop(0)[2:].strip() or title
            while lines and not lines[0]:
                lines.pop(0)
        if not lines:
            fail("config/terms-of-use.md is empty.")
        lines = fill_terms(lines, s, chat_retention, temp_retention)
        cfg["interface"]["termsOfService"] = {"modalAcceptance": True, "modalTitle": title, "modalContent": lines}

    if setup["SPEECH"]:
        stt_model = s.get("STT_MODEL", "")
        tts_model = s.get("TTS_MODEL", "")
        speech = {}
        if stt_model:
            speech["stt"] = {
                "openai": {
                    "url": "http://bifrost:8080/v1/audio/transcriptions",
                    "apiKey": "${STT_API_KEY}",
                    "model": f"openai/{stt_model}",
                },
                "allowedAddresses": ["bifrost:8080"],
            }
        if tts_model:
            speech["tts"] = {
                "openai": {
                    "url": "http://bifrost:8080/v1/audio/speech",
                    "apiKey": "${TTS_API_KEY}",
                    "model": f"openai/{tts_model}",
                    "voices": TTS_VOICES,
                },
                "allowedAddresses": ["bifrost:8080"],
            }
        if speech:
            # defaults for the speech menu of all users. LibreChat only applies them as long as a user
            # has not changed the respective setting (their own choice is kept).
            tab = {}
            if stt_model:
                tab["speechToText"] = {
                    "engineSTT": "external",
                    "languageSTT": "de-DE",
                    "autoTranscribeAudio": True,
                    "decibelValue": -65,
                    "autoSendText": 3,
                }
            if tts_model:
                voice = s.get("TTS_VOICE", "") or "fable"
                if voice not in TTS_VOICES:
                    fail(f"{where}: TTS_VOICE={voice!r} is not an allowed voice ({', '.join(TTS_VOICES)}).")
                tab["textToSpeech"] = {
                    "engineTTS": "external",
                    "voice": voice,
                    "automaticPlayback": False,
                    "playbackRate": 1,
                    "cacheTTS": True,
                }
            speech["speechTab"] = tab
            cfg["speech"] = speech
    # without speech input/output: hide the microphone and the read-aloud button (otherwise LibreChat falls back to
    # the browser's own speech recognition – in Chrome the audio goes to Google)
    tab = cfg.setdefault("speech", {}).setdefault("speechTab", {})
    if "speechToText" not in tab:
        tab["speechToText"] = False
    if "textToSpeech" not in tab:
        tab["textToSpeech"] = False

    if onyx_ready:
        cfg["mcpServers"] = {
            "intranet": {
                "type": "streamable-http",
                "url": "http://onyx-mcp:8090/",
                "headers": {"Authorization": "Bearer ${ONYX_API_KEY}"},
                "timeout": 60000,
            }
        }
        cfg["mcpSettings"] = {"allowedAddresses": ["onyx-mcp:8090"]}

    header = [
        "# ============================================================================",
        "# GENERATED by /opt/kira/scripts/librechat-config.py – do NOT edit by hand (it is overwritten).",
        "# To change: agents in /opt/kira/agents/, switches in /opt/kira/env/setup.env, then bash /opt/kira/setup.sh",
        "# Docs: https://www.librechat.ai/docs/configuration/librechat_yaml",
        "# ============================================================================",
    ]
    text = "\n".join(header + emit(cfg)) + "\n"
    out_path = os.path.join(KIRA_DIR, "config", "librechat.yaml")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, out_path)

    # plan for the agents per Keycloak group (applied in LibreChat by scripts/agent-groups.sh,
    # builders by scripts/builder-sync.py)
    plan["image_agent"] = {"id": image_agent_id, "endpoint": IMAGE_ENDPOINT, "model": IMAGE_AGENT_MODEL} \
        if image_agent_id else None
    plan["endpoints"] = [e["name"] for e in custom]
    plan["builder_priority"] = BUILDER_PRIORITY
    # permissions of the group roles, derived from the interface settings above (not copied from USER: LibreChat
    # updates USER only when it starts, the copy could be stale) + "+"/multiConvo only for admins
    plan["role_permissions"] = role_permissions(cfg["interface"])
    plan["role_permissions"]["MULTI_CONVO"] = {"USE": False}
    # creating agents: groups only with own agents (the builder itself only appears for BUILDER_GROUP) or in
    # agent builder mode; sharing only in agent builder mode; admins always
    plan["role_permissions"]["AGENTS"] = {"USE": True, "CREATE": builder or bool(plan.get("builders")),
                                          "SHARE": builder, "SHARE_PUBLIC": builder}
    plan["system_permissions"] = {
        "USER": {"MULTI_CONVO": {"USE": False},
                 "AGENTS": {"USE": True, "CREATE": builder, "SHARE": builder, "SHARE_PUBLIC": builder}},
        "ADMIN": {"MULTI_CONVO": {"USE": True},
                  "AGENTS": {"USE": True, "CREATE": True, "SHARE": True, "SHARE_PUBLIC": True}},
    }
    if plan["enabled"] and plan["builders"] and builder:
        notes.append("agent builder is ON – the model groups' limits only apply again after agent-builder.sh off")
    write_json(os.path.join(KIRA_DIR, "config", "agent-groups.json"), plan)

    print(f"config/librechat.yaml generated: {len(specs)} agents ({', '.join(x['label'] for x in specs)}).")
    if plan["enabled"]:
        labels = {sp["name"]: sp["label"] for sp in specs}
        for g in plan["priority"]:
            print(f"  Group {g}: {', '.join(labels[i['name']] for i in plan['roles'][g])}")
        print(f"  Group {plan['admin_group']} (admins): all agents")
        print("  without one of these groups: no login, no agent")
        print(f"  Own agents: members of {plan['builder_group']} (plus {plan['admin_group']}) with the models of "
              "their model groups:")
        for g, b in plan["builders"].items():
            print(f"    Model group {g}: {', '.join(b['models'])}")
        for name, mods in plan["builder_endpoints"].items():
            print(f"  Agent builder, provider \"{name}\": {', '.join(mods)} (each user sees only the models of their groups)")
    for note in notes:
        print(f"  Note: {note}")
    if builder:
        print("  Note: agent builder is ON (creating/sharing agents allowed) – afterwards: scripts/agent-builder.sh off")


if __name__ == "__main__":
    main()
