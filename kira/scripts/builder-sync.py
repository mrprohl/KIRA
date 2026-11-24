#!/usr/bin/env python3
# ============================================================================
# builder-sync.py – own agents (agents/groups.env: BUILDER_GROUP=<group>, builder.<model group>=<models>)
#
#   Reads from Keycloak (admin API, service account from env/keycloak-sync.env) who is in BUILDER_GROUP
#   (may build agents: yes/no) and in which model groups (which models), and gives everyone who is in
#   BUILDER_GROUP and in at least one model group a personal LibreChat profile:
#     - agent builder visible, providers/models = those of their model groups (+ image agent)
#     - own agents selectable next to the fixed agents ("Meine Agenten")
#   Several model groups add up. Members of the admin group (ADMIN_GROUP) build without these groups: all
#   models and all parameters. Profiles of users who lost the permission are removed. LibreChat applies
#   changes within about 1 minute (no restart).
#
#   Runs every 5 minutes via /etc/cron.d/kira; manually:
#     python3 /opt/kira/scripts/builder-sync.py            show what is applied
#     python3 /opt/kira/scripts/builder-sync.py --dry-run  only show the memberships, change nothing
#   Users who have never logged in to KIRA get their profile after their first login (next run).
#   Python standard library + curl only.
# ============================================================================
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.parse

KIRA_DIR = os.environ.get("KIRA_DIR", "/opt/kira")
PLAN = os.path.join(KIRA_DIR, "config", "agent-groups.json")
STATE = os.path.join(KIRA_DIR, "config", "builder-sync.state.json")
CRED = os.path.join(KIRA_DIR, "env", "keycloak-sync.env")
JS = os.path.join(KIRA_DIR, "scripts", "builder-sync.js")
PENDING_RECHECK = 15 * 60          # users without a LibreChat account: look again every 15 minutes
QUIET = "--quiet" in sys.argv
DRY = "--dry-run" in sys.argv


def say(msg):
    if not QUIET:
        print(msg)


def read_env(path):
    values = {}
    if not os.path.exists(path):
        return values
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key.strip()] = value
    return values


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def save_state(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=1)
    os.chmod(tmp, 0o600)        # contains Keycloak user IDs
    os.replace(tmp, STATE)


def quote(value):
    """Value for a curl config line (in "…")."""
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


class Keycloak:
    """Keycloak admin API via curl; secrets and token go through stdin (-K -), not the command line."""

    def __init__(self, issuer, resolve, client_id, secret):
        parsed = urllib.parse.urlsplit(issuer)
        parts = parsed.path.rstrip("/").split("/")
        if len(parts) < 3 or parts[-2] != "realms":
            raise RuntimeError(f"OPENID_ISSUER {issuer!r} – expected …/realms/<realm>")
        self.realm = parts[-1]
        self.root = f"{parsed.scheme}://{parsed.netloc}{'/'.join(parts[:-2])}"
        self.resolve = resolve
        self.client_id = client_id
        self.secret = secret
        self.token = None

    def _curl(self, config_lines):
        args = ["curl", "-sS", "-m", "20", "-K", "-", "-w", "\n%{http_code}\n%header{server}"]
        for r in self.resolve:
            args += ["--resolve", r]
        res = subprocess.run(args, input="\n".join(config_lines) + "\n", capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"Keycloak not reachable: {res.stderr.strip() or 'curl exit ' + str(res.returncode)}")
        rest, _, server = res.stdout.rpartition("\n")
        body, _, code = rest.rpartition("\n")
        self.last = f"server: {server or '-'}, answer: {body.strip()[:160] or '-'}"
        return int(code or 0), body

    def login(self):
        code, body = self._curl([
            f"url = {quote(self.root + '/realms/' + self.realm + '/protocol/openid-connect/token')}",
            f"data-urlencode = {quote('grant_type=client_credentials')}",
            f"data-urlencode = {quote('client_id=' + self.client_id)}",
            f"data-urlencode = {quote('client_secret=' + self.secret)}",
        ])
        if code != 200:
            raise RuntimeError(f"Keycloak login of {self.client_id} failed (HTTP {code}) – client/secret in "
                               "env/keycloak-sync.env, \"Service accounts roles\" on?")
        self.token = json.loads(body)["access_token"]

    def get(self, path, **params):
        url = f"{self.root}/admin/realms/{self.realm}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        code, body = self._curl([f"url = {quote(url)}", f"header = {quote('Authorization: Bearer ' + self.token)}"])
        if code == 403:
            raise RuntimeError(f"Keycloak: HTTP 403 for {url.split('?')[0]} ({self.last}) – either the service "
                               "account lacks view-users/query-groups (realm-management) or a proxy in front of "
                               "Keycloak blocks /admin")
        if code == 401:
            raise RuntimeError(f"Keycloak: HTTP 401 for {url.split('?')[0]} ({self.last}) – since Keycloak 26.8.2 "
                               "the client kira-sync needs the client scope kc-admin-api as Default (README, "
                               "section \"Own agents\")")
        if code != 200:
            raise RuntimeError(f"Keycloak: {url.split('?')[0]} → HTTP {code} ({self.last})")
        return json.loads(body)

    def members(self, group):
        found = [g for g in self.get("/groups", search=group, exact="true", briefRepresentation="true")
                 if g.get("name") == group]
        if not found:
            return None
        users, first, size = [], 0, 500
        while True:
            page = self.get(f"/groups/{found[0]['id']}/members", first=first, max=size, briefRepresentation="true")
            users += [u["id"] for u in page if u.get("enabled", True)]
            if len(page) < size:
                return users
            first += size


ADMIN = "(admin)"   # marker in the group list of a user: member of the admin group
ADMIN_DROP_PARAMS = ["useResponsesApi", "web_search"]


def run_js(payload):
    """Apply the profiles in LibreChat (inside the container); returns the result line of builder-sync.js."""
    with open(JS, encoding="utf-8") as fh:
        script = fh.read()
    b64 = base64.b64encode(json.dumps(payload).encode()).decode()
    src = f"'use strict';\nprocess.env.KIRA_BUILDERS = '{b64}';\n{script}"
    res = subprocess.run(["docker", "exec", "-i", "-w", "/app", "librechat", "node", "-"],
                         input=src, capture_output=True, text=True)
    lines = [ln for ln in res.stdout.splitlines() if ln.startswith("KIRA_RESULT ")]
    if res.returncode != 0 or not lines:
        err = [ln for ln in (res.stderr + res.stdout).splitlines() if ln.startswith("Error")]
        raise RuntimeError(err[-1] if err else f"builder-sync.js failed (exit {res.returncode})")
    for ln in res.stdout.splitlines():
        if ln.startswith("  "):
            say(ln)
    return json.loads(lines[-1][len("KIRA_RESULT "):])


def librechat_healthy():
    res = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}",
                          "librechat"], capture_output=True, text=True)
    return res.returncode == 0 and res.stdout.strip() in ("true/healthy", "true/")


def slack(text):
    """Message to Slack (German, like the other KIRA messages); the webhook URL goes via stdin (-K -)."""
    url = read_env(os.path.join(KIRA_DIR, "env", "monitoring.env")).get("SLACK_WEBHOOK_URL", "")
    if not url:
        return
    subprocess.run(["curl", "-fsS", "-m", "15", "-o", "/dev/null", "-H", "Content-Type: application/json",
                    "--data-binary", json.dumps({"text": text}), "-K", "-"],
                   input=f"url = {quote(url)}\n", capture_output=True, text=True)


def main():
    if os.geteuid() != 0:
        sys.exit("Error: please run as root.")
    plan = load_json(PLAN, {})
    state = load_json(STATE, {})
    builders = (plan.get("builders") or {}) if plan.get("enabled") else {}
    priority = plan.get("builder_priority", 137)
    image = plan.get("image_agent")

    desired = {}          # sub → sorted model groups (ADMIN for admins)
    if builders:
        cred = read_env(CRED)
        if not cred.get("KC_SYNC_CLIENT_ID") or not cred.get("KC_SYNC_CLIENT_SECRET"):
            say("Own agents are defined (agents/groups.env), but env/keycloak-sync.env (KC_SYNC_CLIENT_ID/KC_SYNC_CLIENT_SECRET) "
                "is missing – nothing synchronised (README, section \"Own agents\").")
            return 0
        lc = read_env(os.path.join(KIRA_DIR, "env", "librechat.env"))
        comp = read_env(os.path.join(KIRA_DIR, "env", "compose.env"))
        resolve = []
        if comp.get("KEYCLOAK_HOST") and comp.get("KEYCLOAK_IP"):
            resolve.append(f"{comp['KEYCLOAK_HOST']}:443:{comp['KEYCLOAK_IP']}")
        kc = Keycloak(lc.get("OPENID_ISSUER", ""), resolve, cred["KC_SYNC_CLIENT_ID"], cred["KC_SYNC_CLIENT_SECRET"])
        kc.login()
        # may build = member of BUILDER_GROUP; which models = membership in the model groups (builder.<group>=…)
        builder_group = plan.get("builder_group") or ""
        found = kc.members(builder_group) if builder_group else None
        may_build = set(found or [])
        if builder_group:
            if found is None:
                say(f"  Note: group {builder_group} (BUILDER_GROUP) does not exist in Keycloak (realm {kc.realm}) – "
                    "nobody except the admins may build agents.")
            else:
                say(f"  Group {builder_group} (may build agents): {len(may_build)} member(s)")
        in_model_group = set()
        for group in builders:
            subs = kc.members(group)
            if subs is None:
                say(f"  Note: model group {group} does not exist in Keycloak (realm {kc.realm}).")
                continue
            say(f"  Model group {group}: {len(subs)} member(s)")
            in_model_group.update(subs)
            for sub in subs:
                if sub in may_build:
                    desired.setdefault(sub, []).append(group)
        no_models = may_build - in_model_group
        if no_models:
            say(f"  Note: {len(no_models)} member(s) of {builder_group} without a model group – no builder for them.")
        # admins build without these groups: all models and all parameters
        admin_group = plan.get("admin_group") or ""
        if admin_group:
            subs = kc.members(admin_group)
            if subs is None:
                say(f"  Note: admin group {admin_group} does not exist in Keycloak (realm {kc.realm}).")
            else:
                say(f"  Admin group {admin_group}: {len(subs)} member(s) – all models and parameters")
                for sub in subs:
                    desired.setdefault(sub, []).append(ADMIN)

    users = []
    for sub, groups in sorted(desired.items()):
        groups = sorted(set(groups))
        admin = ADMIN in groups
        mine = {m for g in groups if g != ADMIN for m in builders[g]["models"]}
        providers, custom = [], []
        for name, mods in (plan.get("builder_endpoints") or {}).items():
            usable = list(mods) if admin else [m for m in mods if m in mine]   # order as in agents/groups.env
            if usable:
                providers.append(name)
                # same endpoint, but only the models of this user's model groups (LibreChat checks every message)
                entry = {"name": name, "models": {"default": usable, "fetch": False}}
                if admin:
                    # all parameters in the builder (and when the admin chats) – except the technical switches
                    # Bifrost does not serve (OpenAI Responses API, OpenAI's own web search)
                    entry["dropParams"] = ADMIN_DROP_PARAMS
                custom.append(entry)
        if image and image.get("endpoint") and image["endpoint"] not in providers:
            providers.append(image["endpoint"])
        users.append({"sub": sub, "groups": groups, "overrides": {
            "interface": {"modelSelect": True},
            "endpoints": {"agents": {"disableBuilder": False, "allowedProviders": providers}, "custom": custom},
            "modelSpecs": {"enforce": False, "addedEndpoints": ["agents"]},
        }})
    fingerprint = hashlib.sha256(json.dumps([priority, users], sort_keys=True).encode()).hexdigest()

    if DRY:
        for u in users:
            eps = "; ".join(f"{c['name']}: {', '.join(c['models']['default'])}" for c in u["overrides"]["endpoints"]["custom"])
            print(f"  {u['sub']}: {', '.join(u['groups'])} → {eps or '-'}")
        print(f"Dry run: {len(users)} builder(s), nothing changed.")
        return 0

    pending_due = state.get("pending") and time.time() - state.get("checked", 0) >= PENDING_RECHECK
    if fingerprint == state.get("fingerprint") and not pending_due and not state.get("error") and QUIET:
        return 0
    if not users and not state.get("fingerprint") and QUIET:
        return 0           # never had builders – nothing to clean up

    if QUIET and not librechat_healthy():
        return 0           # LibreChat is (re)starting, e.g. during setup.sh – the next run applies the changes
    result = run_js({"priority": priority, "users": users})
    state.update({"fingerprint": fingerprint, "pending": result.get("pending", []), "checked": time.time()})
    if state.pop("error", None):
        slack(":white_check_mark: KIRA: Abgleich der Builder-Gruppen (eigene Agenten) läuft wieder.")
    save_state(state)
    changed = result.get("applied", 0) + result.get("removed", 0)
    if changed or not QUIET:
        print(f"Builder sync: {len(users)} builder(s) – {result.get('applied', 0)} profile(s) set, "
              f"{result.get('removed', 0)} removed, {result.get('unchanged', 0)} unchanged, "
              f"{len(result.get('pending', []))} without a KIRA account yet (after their first login).")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 – one message for cron/syslog and Slack
        msg = str(exc) or exc.__class__.__name__
        print(f"Error: {msg}", file=sys.stderr)
        st = load_json(STATE, {})
        if not DRY and st.get("error") != msg:
            if not st.get("error"):
                slack(f":warning: KIRA: Abgleich der Builder-Gruppen (eigene Agenten) fehlgeschlagen – {msg} (Details: journalctl -t kira-builders)")
            st["error"] = msg
            try:
                save_state(st)
            except OSError:
                pass
        sys.exit(1)
