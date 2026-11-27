"""Shared helpers of the KIRA document services: configuration, access rules, HTTP, logging."""
import json
import logging
import os
import re
import urllib.error
import urllib.request

AGENTS_FILE = os.environ.get("KIRA_DOCS_AGENTS", "/config/docs-agents.json")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
DOC_ID_RE = re.compile(r"^kira-[a-z0-9-]+-[0-9a-f]{24}$")


def setup_logging(name):
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s " + name + ": %(message)s")
    return logging.getLogger(name)


def env(name, default=None, required=False):
    value = os.environ.get(name, default)
    if required and not value:
        raise SystemExit(f"{name} is not set")
    return value


def load_agents(path=AGENTS_FILE):
    """docs-agents.json, written by /opt/kira/scripts/librechat-config.py:
    {"agents": {"<name>": {"label", "docs", "templates", "confidential"}},
     "access": {"agent_groups": bool, "admin_group": str, "groups": {"<group>": ["<agent>", …]},
                "priority": ["<group>", …]}}"""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {"agents": {}, "access": {"agent_groups": False, "admin_group": "", "groups": {}, "priority": []}}
    agents = {n: a for n, a in (data.get("agents") or {}).items() if NAME_RE.match(n)}
    access = data.get("access") or {}
    return {"agents": agents, "access": {"agent_groups": bool(access.get("agent_groups")),
                                         "admin_group": access.get("admin_group") or "",
                                         "groups": access.get("groups") or {},
                                         "priority": access.get("priority") or list(access.get("groups") or {})}}


def role_may_use(cfg, agent, role):
    """LibreChat role (MCP header {{LIBRECHAT_USER_ROLE}}) may use the documents of this agent?
    With agents per group the role is the Keycloak group (one per user), ADMIN sees all; otherwise every
    logged-in user (USER/ADMIN) sees all agents."""
    a = cfg["agents"].get(agent)
    if not a or not a.get("docs"):
        return False
    role = (role or "").strip()
    if not role:
        return False
    if role == "ADMIN":
        return True
    acc = cfg["access"]
    if not acc["agent_groups"]:
        return role == "USER"
    return agent in (acc["groups"].get(role) or [])


def groups_may_use(cfg, agent, groups):
    """Keycloak claims passed by the login service (groups – or roles user/admin without agents per group)."""
    a = cfg["agents"].get(agent)
    if not a or not a.get("docs"):
        return False
    groups = {g.strip().lstrip("/") for g in groups if g and g.strip()}
    acc = cfg["access"]
    if not acc["agent_groups"]:
        return bool(groups & {"user", "admin"})
    if acc["admin_group"] and acc["admin_group"] in groups:
        return True
    # like LibreChat: a user in several groups gets the group with the most agents (order: access.priority)
    group = next((g for g in acc["priority"] if g in groups), None)
    return bool(group) and agent in (acc["groups"].get(group) or [])


def http_json(method, url, body=None, token=None, timeout=60, headers=None):
    """JSON request with Bearer token; returns (status, parsed body or text)."""
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as err:
        raw = err.read()
        status = err.code
    text = raw.decode("utf-8", "replace")
    try:
        return status, json.loads(text) if text else None
    except ValueError:
        return status, text
