"""docs-sync – every DOCS_INTERVAL seconds: agent folders on the NAS (SMB 2/3, read only) → copy on the KIRA server,
text (direct, OCR, image model) → Onyx (one connector + document set per agent); templates (_vorlagen) are only copied.

  python -m kiradocs.sync              run forever
  python -m kiradocs.sync --once       one pass
  python -m kiradocs.sync --estimate   count pages/images that would go to the image model (no model calls)
  python -m kiradocs.sync --check      test the NAS connection, list which agent folders exist (setup.sh)
"""
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
from datetime import datetime, timezone

from . import extract, templates
from .common import env, http_json, load_agents, setup_logging
from .onyx import Onyx, OnyxError

log = setup_logging("docs-sync")
DATA = env("DATA_DIR", "/data")
MIRROR = os.path.join(DATA, "mirror")
TEMPLATES = os.path.join(DATA, "templates")
SKILLS = env("SKILLS_DIR", "/skills")          # bind mount /opt/docs/skills – LibreChat reads skills/live
STATUS = os.path.join(DATA, "status.json")
MAX_MB = int(env("MAX_FILE_MB", "100"))
SECTION_CHARS = 20000
RETRY_SKIPPED_H = 24


def doc_id(agent, rel):
    return f"kira-{agent}-" + hashlib.sha256(f"{agent}/{rel}".encode()).hexdigest()[:24]


class State:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute("""CREATE TABLE IF NOT EXISTS files (agent TEXT, rel TEXT, size INT, mtime REAL, sha TEXT,
            doc_id TEXT, method TEXT, pages INT, updated REAL, PRIMARY KEY (agent, rel))""")
        self.db.execute("CREATE TABLE IF NOT EXISTS agents (agent TEXT PRIMARY KEY, cc_pair INT)")
        self.db.execute("""CREATE TABLE IF NOT EXISTS cache (sha TEXT PRIMARY KEY, pages TEXT, method TEXT,
            created REAL)""")
        self.db.commit()

    def files(self, agent):
        cur = self.db.execute("SELECT rel, size, mtime, sha, doc_id, method, updated FROM files WHERE agent=?",
                              (agent,))
        return {r[0]: {"size": r[1], "mtime": r[2], "sha": r[3], "doc_id": r[4], "method": r[5], "updated": r[6]}
                for r in cur}

    def put_file(self, agent, rel, size, mtime, sha, did, method, pages):
        self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?,?,?)",
                        (agent, rel, size, mtime, sha, did, method, pages, time.time()))
        self.db.commit()

    def drop_file(self, agent, rel):
        self.db.execute("DELETE FROM files WHERE agent=? AND rel=?", (agent, rel))
        self.db.commit()

    def cc_pair(self, agent):
        row = self.db.execute("SELECT cc_pair FROM agents WHERE agent=?", (agent,)).fetchone()
        return row[0] if row else None

    def set_cc_pair(self, agent, cc):
        self.db.execute("INSERT OR REPLACE INTO agents VALUES (?,?)", (agent, cc))
        self.db.commit()

    def cached(self, sha):
        row = self.db.execute("SELECT pages FROM cache WHERE sha=?", (sha,)).fetchone()
        return json.loads(row[0]) if row else None

    def cache(self, sha, pages):
        method = ",".join(sorted({p["method"] for p in pages}))
        self.db.execute("INSERT OR REPLACE INTO cache VALUES (?,?,?,?)", (sha, json.dumps(pages), method, time.time()))
        self.db.commit()

    def uncache(self, sha):
        self.db.execute("DELETE FROM cache WHERE sha=?", (sha,))
        self.db.commit()


class Nas:
    """SMB 2/3 via smbprotocol (no SMB 1). Paths: \\\\host\\share\\<agent>\\…"""

    def __init__(self):
        import smbclient
        self.smb = smbclient
        self.host = env("NAS_HOST", required=True)
        self.share = env("NAS_SHARE", required=True)
        user = env("NAS_USER", required=True)
        domain = env("NAS_DOMAIN", "")
        smbclient.ClientConfig(username=f"{domain}\\{user}" if domain else user, password=env("NAS_PASSWORD", ""),
                               require_secure_negotiate=True)
        self.root = f"\\\\{self.host}\\{self.share}"

    def path(self, *parts):
        return "\\".join([self.root, *[p.replace("/", "\\") for p in parts if p]])

    def exists(self, agent):
        try:
            return self.smb.path.isdir(self.path(agent))
        except Exception:  # noqa: BLE001
            return False

    def walk(self, agent, exclude, only=None):
        """→ {relpath (with /): (size, mtime)} below <agent> (or <agent>/<only>); excluded folder names skipped."""
        out = {}
        base = self.path(agent, only) if only else self.path(agent)
        stack = [""]
        while stack:
            sub = stack.pop()
            for e in self.smb.scandir(base + ("\\" + sub.replace("/", "\\") if sub else "")):
                rel = f"{sub}/{e.name}" if sub else e.name
                if e.is_dir():
                    if not only and not sub and e.name.lower() in exclude:
                        continue
                    if e.name.startswith(".") or e.name.lower() in {"$recycle.bin", "#recycle", "@eadir"}:
                        continue
                    stack.append(rel)
                elif e.is_file():
                    st = e.stat()
                    out[rel] = (st.st_size, st.st_mtime)
        return out

    def copy(self, agent, rel, dest, only=None):
        src = self.path(agent, only, rel) if only else self.path(agent, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        h = hashlib.sha256()
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest))
        try:
            with self.smb.open_file(src, mode="rb") as fin, os.fdopen(fd, "wb") as fout:
                for chunk in iter(lambda: fin.read(1 << 20), b""):
                    h.update(chunk)
                    fout.write(chunk)
            os.replace(tmp, dest)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        return h.hexdigest()


def safe_join(base, rel):
    path = os.path.normpath(os.path.join(base, rel))
    if not path.startswith(os.path.normpath(base) + os.sep):
        raise ValueError(f"path outside the folder: {rel}")
    return path


def make_document(agent, rel, pages, url):
    name = os.path.basename(rel)
    sections, methods = [], {p["method"] for p in pages}
    auto = bool(methods & {"ocr", "vision"})
    for p in pages:
        text = (p.get("text") or "").strip()
        if not text:
            continue
        if p["method"] in ("ocr", "vision"):
            text = "[Automatisch übertragen – Lesefehler möglich]\n" + text
        link = f"{url}#page={p['page']}" if p.get("page") else url
        for i in range(0, len(text), SECTION_CHARS):
            sections.append({"type": "text", "text": text[i:i + SECTION_CHARS], "link": link,
                             **({"heading": f"Seite {p['page']}"} if p.get("page") else {})})
    if not sections:
        reason = ("nicht übertragen – Datenschutz" if "skipped-privacy" in methods else
                  "Inhalt nicht auslesbar (z. B. Handschrift oder Foto ohne Bildübertragung)")
        sections = [{"type": "text", "link": url, "text": f"Datei {name} im Ordner {os.path.dirname(rel) or '/'}: {reason}."}]
    meta = {"agent": agent, "pfad": rel,
            "erfassung": "automatisch übertragen" if auto else ("Volltext" if "text" in methods else "nur Dateiname")}
    return {"id": doc_id(agent, rel), "semantic_identifier": name, "title": name, "source": "ingestion_api",
            "sections": sections, "metadata": meta, "doc_updated_at": datetime.now(timezone.utc).isoformat()}


def write_json(path, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def index_of(state, agent):
    return {r["doc_id"]: rel for rel, r in state.files(agent).items()}


class Syncer:
    def __init__(self):
        self.domain = env("KIRA_DOMAIN", required=True)
        self.exclude = {"_vorlagen", *[x.strip().lower() for x in env("EXCLUDE_DIRS", "_archiv").split(",") if x.strip()]}
        self.state = State(os.path.join(DATA, "state.db"))
        self.nas = Nas()
        self.onyx = Onyx(env("ONYX_URL", "http://onyx-api:8080"), env("ONYX_ADMIN_KEY", ""), log)
        self.vision = extract.Vision(env("VISION", "false") == "true", env("BIFROST_URL", "http://bifrost:8080/v1"),
                                     env("DOCS_VK", ""), env("VISION_MODEL", "anthropic/claude-sonnet-5-5"),
                                     http_json, log)
        # agents with CONFIDENTIAL=true: images only to a local model (VISION_LOCAL_MODEL, e.g. vllm/kira-vision via
        # Bifrost); without one only the OCR text is used
        local = env("VISION_LOCAL_MODEL", "")
        self.vision_local = extract.Vision(bool(local) and env("VISION", "false") == "true",
                                           env("BIFROST_URL", "http://bifrost:8080/v1"), env("DOCS_VK", ""), local,
                                           http_json, log)

    def url(self, agent, did):
        return f"https://{self.domain}/dokumente/{agent}/{did}"

    def sync_docs(self, agent, label, stats, confidential=False):
        vision = self.vision_local if confidential else self.vision
        if not self.onyx.key:
            raise OnyxError("ONYX_ADMIN_KEY is empty – set it in /opt/docs/env/docs-sync.env (setup.sh)")
        cc = self.onyx.ensure_agent(agent, label, self.state.cc_pair(agent))
        self.state.set_cc_pair(agent, cc)
        remote = self.nas.walk(agent, self.exclude)
        known = self.state.files(agent)
        base = os.path.join(MIRROR, agent)
        for rel, (size, mtime) in sorted(remote.items()):
            ext = os.path.splitext(rel)[1].lower()
            old = known.get(rel)
            # not sent (privacy), failed, or not readable while an image model is available (e.g. switched on later):
            # try again after a day
            again = old and old["method"] and ("skipped-privacy" in old["method"] or "error" in old["method"]
                                               or ("none" in old["method"] and vision.enabled))
            retry = again and time.time() - (old["updated"] or 0) > RETRY_SKIPPED_H * 3600
            if old and old["size"] == size and abs((old["mtime"] or 0) - mtime) < 1 and not retry:
                continue
            if size > MAX_MB * 1024 * 1024:
                log.warning("%s/%s: larger than %s MB – skipped", agent, rel, MAX_MB)
                stats["skipped"] += 1
                continue
            dest = safe_join(base, rel)
            sha = self.nas.copy(agent, rel, dest)
            did = doc_id(agent, rel)
            pages = self.state.cached(sha) if not retry else None
            if pages is None:
                try:
                    pages = (extract.extract(dest, vision) if ext in extract.SUPPORTED
                             else [{"page": None, "text": "", "method": "none"}])
                except Exception as err:  # noqa: BLE001 – one broken file must not stop the run
                    log.warning("%s/%s: cannot read (%s)", agent, rel, err)
                    pages = [{"page": None, "text": "", "method": "error"}]
                # only final results are reused for identical files (not: failed, not sent, not readable)
                if not any(p["method"] in ("error", "skipped-privacy", "none") for p in pages):
                    self.state.cache(sha, pages)
            self.onyx.upsert(cc, make_document(agent, rel, pages, self.url(agent, did)))
            method = ",".join(sorted({p["method"] for p in pages}))
            self.state.put_file(agent, rel, size, mtime, sha, did, method, len(pages))
            stats["updated"] += 1
            log.info("%s/%s: indexed (%s)", agent, rel, method)
        for rel, old in known.items():
            if rel not in remote:
                self.onyx.delete(old["doc_id"])
                try:
                    os.unlink(safe_join(base, rel))
                except (OSError, ValueError):
                    pass
                self.state.drop_file(agent, rel)
                stats["deleted"] += 1
                log.info("%s/%s: removed", agent, rel)
        write_json(os.path.join(MIRROR, f"{agent}.index.json"), index_of(self.state, agent))
        stats["files"] += len(remote)

    def sync_templates(self, agent):
        """<agent>/_vorlagen → /data/templates/<agent>/ (exact copy; templates.publish() turns it into the skill)."""
        base = os.path.join(TEMPLATES, agent)
        if not self.nas.exists(f"{agent}\\_vorlagen"):
            shutil.rmtree(base, ignore_errors=True)
            return
        remote = self.nas.walk(agent, set(), only="_vorlagen")
        os.makedirs(base, exist_ok=True)
        for rel, (size, _mtime) in remote.items():
            if size > 10 * 1024 * 1024:
                log.warning("%s/_vorlagen/%s: larger than 10 MB – skipped (limit of LibreChat skills)", agent, rel)
                continue
            dest = safe_join(base, rel)
            if not (os.path.exists(dest) and os.path.getsize(dest) == size):
                self.nas.copy(agent, rel, dest, only="_vorlagen")
        for dirpath, _dirs, files in os.walk(base):
            for f in files:
                rel = os.path.relpath(os.path.join(dirpath, f), base).replace(os.sep, "/")
                if rel not in remote:
                    os.unlink(os.path.join(dirpath, f))

    def run_once(self):
        cfg = load_agents()
        status = {"started": datetime.now(timezone.utc).isoformat(), "agents": {}, "vision_calls": 0}
        for agent, a in sorted(cfg["agents"].items()):
            stats = {"files": 0, "updated": 0, "deleted": 0, "skipped": 0, "error": ""}
            try:
                if not self.nas.exists(agent):
                    stats["error"] = f"folder {agent} missing on the NAS"
                    log.warning("folder %s is missing on the NAS", agent)
                else:
                    if a.get("docs"):
                        self.sync_docs(agent, a.get("label") or agent, stats, bool(a.get("confidential")))
                    if a.get("templates"):
                        self.sync_templates(agent)
                    elif os.path.isdir(os.path.join(TEMPLATES, agent)):
                        shutil.rmtree(os.path.join(TEMPLATES, agent), ignore_errors=True)
            except Exception as err:  # noqa: BLE001 – report per agent, go on with the next
                stats["error"] = str(err)[:300]
                log.error("%s: %s", agent, err)
            status["agents"][agent] = stats
        try:
            status["templates"] = templates.publish(
                {n: a.get("label") or n for n, a in cfg["agents"].items() if a.get("templates")}, TEMPLATES, SKILLS, log)
        except OSError as err:
            log.error("templates: %s", err)
            status["templates_error"] = str(err)[:300]
        status["finished"] = datetime.now(timezone.utc).isoformat()
        status["vision_calls"] = self.vision.calls + self.vision_local.calls
        write_json(STATUS, status)
        return status

    def check(self):
        """Connection test for setup.sh: exit 0 if the share is readable; prints the agent folders."""
        cfg = load_agents()
        try:
            self.nas.smb.listdir(self.nas.root)
        except Exception as err:  # noqa: BLE001
            print(f"NAS: \\\\{self.nas.host}\\{self.nas.share} not readable: {err}")
            return 1
        print(f"NAS: \\\\{self.nas.host}\\{self.nas.share} readable.")
        for agent, a in sorted(cfg["agents"].items()):
            what = ", ".join(w for w, on in (("documents", a.get("docs")), ("templates", a.get("templates"))) if on)
            state = "ok" if self.nas.exists(agent) else "MISSING"
            print(f"  folder {agent} ({what}): {state}")
        return 0

    def estimate(self):
        cfg = load_agents()
        total = 0
        for agent, a in sorted(cfg["agents"].items()):
            if not a.get("docs") or not self.nas.exists(agent):
                continue
            n_files = n_vision = 0
            with tempfile.TemporaryDirectory() as tmp:
                for rel, (size, _m) in self.nas.walk(agent, self.exclude).items():
                    ext = os.path.splitext(rel)[1].lower()
                    if ext not in extract.IMAGE_EXT | {".pdf"} or size > MAX_MB * 1024 * 1024:
                        continue
                    dest = os.path.join(tmp, "f" + ext)
                    self.nas.copy(agent, rel, dest)
                    try:
                        n = extract.estimate(dest)
                    except Exception:  # noqa: BLE001
                        n = 0
                    n_files += 1
                    n_vision += n
            total += n_vision
            print(f"{agent}: {n_files} PDF/image files checked, {n_vision} pages/images would go to the image model")
        print(f"total: {total} model calls (one per page/image, only once – results are cached)")


def main():
    for d in (MIRROR, TEMPLATES):
        os.makedirs(d, exist_ok=True)
    syncer = Syncer()
    if "--check" in sys.argv:
        sys.exit(syncer.check())
    if "--estimate" in sys.argv:
        syncer.estimate()
        return
    interval = int(env("INTERVAL", "900"))
    while True:
        started = time.time()
        try:
            st = syncer.run_once()
            log.info("pass done: %s", {a: {k: v for k, v in s.items() if v} for a, s in st["agents"].items()})
        except Exception as err:  # noqa: BLE001
            log.error("pass failed: %s", err)
        if "--once" in sys.argv:
            return
        time.sleep(max(60, interval - (time.time() - started)))


if __name__ == "__main__":
    main()
