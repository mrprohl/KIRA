"""docs-search – MCP server (streamable HTTP, stateless, JSON answers) with one tool: dokumente_suchen.

LibreChat has one MCP server entry per agent (docs-<agent>), all pointing here; the entry sets fixed headers:
  Authorization: Bearer <DOCS_SEARCH_KEY>     only LibreChat knows it
  X-Kira-Agent:  <agent>                       which document set – from the configuration, not from the model
  X-Kira-Role:   {{LIBRECHAT_USER_ROLE}}       role of the user (group role with agents per group)
  X-Agent-Id:    {{LIBRECHAT_AGENT_ID}}        empty for the fixed KIRA agents, agent_… for own agents (builders)
  X-Kira-User:   {{LIBRECHAT_USER_EMAIL}}      for the log only
A request is answered only if the key matches, the call comes from a fixed agent (no own agent), the agent has
DOCS=true and the user's role may see that agent. The Onyx search then runs on exactly that agent's document set.
"""
import hmac
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .common import env, load_agents, role_may_use, setup_logging
from .onyx import Onyx, OnyxError

log = setup_logging("docs-search")
KEY = env("DOCS_SEARCH_KEY", required=True)
ONYX = Onyx(env("ONYX_URL", "http://onyx-api:8080"), env("ONYX_SEARCH_KEY", ""), log)
PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
MAX_RESULTS = 8
MAX_CHARS = 2500
TOOL = {
    "name": "dokumente_suchen",
    "description": ("Durchsucht die Dokumente dieses Agenten (Ordner auf dem Dateiserver). Nutze das Werkzeug bei "
                    "Fragen zu internen Unterlagen. Gib in der Antwort zu jeder genutzten Fundstelle den Titel als "
                    "Markdown-Link auf das Feld 'link' an. Texte mit dem Hinweis 'Automatisch übertragen' können "
                    "Lesefehler enthalten – weise darauf hin."),
    "inputSchema": {"type": "object", "properties": {
        "frage": {"type": "string", "description": "Suchanfrage in eigenen Worten, möglichst konkret"}},
        "required": ["frage"]},
}
_cfg = {"t": 0.0, "data": None}


def config():
    if time.time() - _cfg["t"] > 30:
        _cfg["data"], _cfg["t"] = load_agents(), time.time()
    return _cfg["data"]


def rpc_result(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def rpc_error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def tool_text(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def search(headers, args):
    agent = (headers.get("X-Kira-Agent") or "").strip()
    role = headers.get("X-Kira-Role") or ""
    user = headers.get("X-Kira-User") or "?"
    if (headers.get("X-Agent-Id") or "").strip():
        log.warning("refused: own agent %s (user %s, %s)", headers.get("X-Agent-Id"), user, agent)
        return tool_text("Die Dokumentensuche steht nur den KIRA-Agenten zur Verfügung.", True)
    if not role_may_use(config(), agent, role):
        log.warning("refused: role %r may not use %s (user %s)", role, agent, user)
        return tool_text("Für diese Dokumente fehlt die Berechtigung.", True)
    query = (args.get("frage") or "").strip()[:2000]
    if not query:
        return tool_text("Bitte eine Suchanfrage angeben.", True)
    try:
        results = ONYX.search(query, f"kira-{agent}")
    except OnyxError as err:
        log.error("search %s: %s", agent, err)
        return tool_text("Die Dokumentensuche ist gerade nicht erreichbar.", True)
    out = [{"titel": r.get("title"), "link": r.get("link"), "stand": r.get("updated_at"),
            "inhalt": (r.get("content") or "")[:MAX_CHARS]} for r in results[:MAX_RESULTS]]
    log.info("search %s by %s: %d results", agent, user, len(out))
    if not out:
        return tool_text("Keine passenden Dokumente gefunden.")
    return tool_text(json.dumps({"ergebnisse": out}, ensure_ascii=False))


def handle(msg, headers):
    if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
        return rpc_error(None, -32600, "invalid request")
    rid, method = msg.get("id"), msg.get("method")
    if rid is None:                       # notification (e.g. notifications/initialized)
        return None
    if method == "initialize":
        asked = (msg.get("params") or {}).get("protocolVersion")
        return rpc_result(rid, {"protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
                                "capabilities": {"tools": {"listChanged": False}},
                                "serverInfo": {"name": "kira-docs", "version": "1.0"}})
    if method == "ping":
        return rpc_result(rid, {})
    if method == "tools/list":
        return rpc_result(rid, {"tools": [TOOL]})
    if method == "tools/call":
        params = msg.get("params") or {}
        if params.get("name") != TOOL["name"]:
            return rpc_error(rid, -32602, "unknown tool")
        return rpc_result(rid, search(headers, params.get("arguments") or {}))
    return rpc_error(rid, -32601, "method not found")


class Handler(BaseHTTPRequestHandler):
    server_version = "kira-docs"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: D102 – access log not needed
        pass

    def _send(self, code, body=None):
        data = b"" if body is None else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            return self._send(200, {"status": "ok"})
        return self._send(405, {"error": "method not allowed"})

    def do_DELETE(self):  # noqa: N802
        return self._send(405, {"error": "method not allowed"})

    def do_POST(self):  # noqa: N802
        if self.path.split("?")[0] != "/mcp":
            return self._send(404, {"error": "not found"})
        auth = self.headers.get("Authorization") or ""
        if not hmac.compare_digest(auth.encode(), f"Bearer {KEY}".encode()):
            return self._send(401, {"error": "unauthorized"})
        length = int(self.headers.get("Content-Length") or 0)
        if length > 1_000_000:
            return self._send(413, {"error": "too large"})
        try:
            body = json.loads(self.rfile.read(length) or b"null")
        except ValueError:
            return self._send(400, rpc_error(None, -32700, "parse error"))
        if isinstance(body, list):
            answers = [a for a in (handle(m, self.headers) for m in body) if a is not None]
            return self._send(200, answers) if answers else self._send(202)
        answer = handle(body, self.headers)
        return self._send(200, answer) if answer is not None else self._send(202)


def main():
    port = int(env("PORT", "8095"))
    log.info("listening on %s", port)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
