"""docs-download – hands out the original files from the copy (/data/mirror, read only) behind the login.

Caddy: /dokumente/oauth2/* → login service (oauth2-proxy); /dokumente/* → forward_auth at the login service, which
answers with X-Auth-Request-Email / X-Auth-Request-Groups (Caddy copies only these, client values are dropped),
then here. Only reachable in the network kira-docsweb (Caddy, login service, this service).

  GET /dokumente/<agent>/<document id>   the file, if the user may see this agent
"""
import json
import mimetypes
import os
import re
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote

from .common import DOC_ID_RE, NAME_RE, env, groups_may_use, load_agents, setup_logging

log = setup_logging("docs-download")
MIRROR = env("MIRROR_DIR", "/data/mirror")
LOG_ON = env("DOWNLOAD_LOG", "true") == "true"
LOG_DAYS = int(env("DOWNLOAD_LOG_DAYS", "90"))
LOG_FILE = env("DOWNLOAD_LOG_FILE", "/logs/downloads.jsonl")
INLINE = {"application/pdf", "image/png", "image/jpeg", "image/gif", "image/webp"}
PATH_RE = re.compile(r"^/dokumente/([a-z0-9][a-z0-9-]{0,40})/(kira-[a-z0-9-]+-[0-9a-f]{24})/?$")
_lock = threading.Lock()


def audit(user, agent, did, name, result):
    if not LOG_ON:
        return
    line = json.dumps({"zeit": datetime.now(timezone.utc).isoformat(timespec="seconds"), "nutzer": user,
                       "agent": agent, "dokument": did, "datei": name, "ergebnis": result}, ensure_ascii=False)
    with _lock:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def prune_log():
    """Delete entries older than DOWNLOAD_LOG_DAYS (or the whole log if logging is off)."""
    if not os.path.exists(LOG_FILE):
        return
    with _lock:
        if not LOG_ON:
            os.unlink(LOG_FILE)
            return
        limit = (datetime.now(timezone.utc) - timedelta(days=LOG_DAYS)).isoformat(timespec="seconds")
        with open(LOG_FILE, encoding="utf-8") as fh:
            keep = [ln for ln in fh if ln[10:35] >= limit]     # '{"zeit": "<iso>' – compare the timestamp
        tmp = LOG_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.writelines(keep)
        os.replace(tmp, LOG_FILE)


def pruner():
    while True:
        try:
            prune_log()
        except OSError as err:
            log.warning("log cleanup: %s", err)
        time.sleep(86400)


def lookup(agent, did):
    """document id → path in the copy (index written by docs-sync), None if unknown."""
    try:
        with open(os.path.join(MIRROR, f"{agent}.index.json"), encoding="utf-8") as fh:
            rel = json.load(fh).get(did)
    except (OSError, ValueError):
        return None
    if not rel:
        return None
    base = os.path.normpath(os.path.join(MIRROR, agent))
    path = os.path.normpath(os.path.join(base, rel))
    if not path.startswith(base + os.sep) or "/_vorlagen/" in f"/{rel.lower()}":
        return None
    return path if os.path.isfile(path) else None


class Handler(BaseHTTPRequestHandler):
    server_version = "kira-docs"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: D102
        pass

    def _plain(self, code, text):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            return self._plain(200, "ok")
        m = PATH_RE.match(unquote(self.path.split("?")[0].split("#")[0]))
        user = (self.headers.get("X-Auth-Request-Email") or "").strip()
        if not user:
            return self._plain(401, "Nicht angemeldet.")
        if not m:
            return self._plain(404, "Nicht gefunden.")
        agent, did = m.group(1), m.group(2)
        if not (NAME_RE.match(agent) and DOC_ID_RE.match(did)):
            return self._plain(404, "Nicht gefunden.")
        groups = (self.headers.get("X-Auth-Request-Groups") or "").split(",")
        if not groups_may_use(load_agents(), agent, groups):
            audit(user, agent, did, None, "verweigert")
            return self._plain(404, "Nicht gefunden.")
        path = lookup(agent, did)
        if not path:
            audit(user, agent, did, None, "unbekannt")
            return self._plain(404, "Nicht gefunden.")
        name = os.path.basename(path)
        ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
        inline = ctype in INLINE
        disp = f"{'inline' if inline else 'attachment'}; filename*=UTF-8''{quote(name)}"
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", ctype if inline else "application/octet-stream")
        self.send_header("Content-Disposition", disp)
        self.send_header("Content-Length", str(size))
        self.send_header("X-Content-Type-Options", "nosniff")
        if ctype != "application/pdf":
            # images: no scripts, no forms; downloads are never rendered. PDFs: a sandbox would stop the browser's
            # PDF viewer – they are shown by the viewer, never as HTML (nosniff, fixed content type)
            self.send_header("Content-Security-Policy", "sandbox; default-src 'none'; img-src 'self'")
        self.send_header("Cache-Control", "private, no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                self.wfile.write(chunk)
        audit(user, agent, did, name, "geliefert")


def main():
    if LOG_ON:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    threading.Thread(target=pruner, daemon=True).start()
    port = int(env("PORT", "8080"))
    log.info("listening on %s (download log %s, %s days)", port, "on" if LOG_ON else "off", LOG_DAYS)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
