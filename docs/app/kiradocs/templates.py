"""Templates (_vorlagen) → one LibreChat skill per agent: vorlagen-<agent>.

docs-sync copies <agent>/_vorlagen from the NAS to /data/templates/<agent>/ and calls publish(). publish() writes the
skills to /skills/live/vorlagen-<agent>/ (SKILL.md + vorlagen/<files>), which LibreChat reads as deployment skills
(DEPLOYMENT_SKILLS_DIR, mounted read-only). LibreChat loads them when it starts – /opt/kira/scripts/templates-reload.sh
restarts it at night when they changed.

LibreChat refuses to start on an invalid skill, so everything here is generated defensively:
  - file names only [a-zA-Z0-9._-] (umlauts transliterated, spaces → _), unique per skill
  - a new skill is built in /skills/tmp and swapped in with rename (never half-written in live/)
  - body below LibreChat's limit (100,000 characters), description 20–1024 characters
"""
import hashlib
import os
import re
import shutil
import unicodedata
import zipfile

TEMPLATE_EXT = {".docx", ".xlsx", ".pptx", ".png", ".jpg", ".jpeg", ".svg"}
MAX_FILE_BYTES = 10 * 1024 * 1024        # LibreChat skill file limit
MAX_HINT_CHARS = 4000
MAX_BODY_CHARS = 90000
PLACEHOLDER_RE = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
SKILL_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
UMLAUTS = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss"})


def skill_name(agent):
    return f"vorlagen-{agent}"


def safe_segment(name):
    """File or folder name → only letters, digits, . _ - (LibreChat rejects everything else)."""
    s = unicodedata.normalize("NFKD", name.translate(UMLAUTS)).encode("ascii", "ignore").decode()
    s = re.sub(r"\s+", "_", s.strip())
    s = re.sub(r"[^A-Za-z0-9._-]", "", s).strip(".")
    return s or "datei"


def placeholders(path):
    """{{ name }} placeholders in a Word/PowerPoint/Excel file (text of the XML parts, tags removed)."""
    found = []
    try:
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                if not info.filename.endswith(".xml") or info.file_size > 20 * 1024 * 1024:
                    continue
                text = re.sub(r"<[^>]+>", "", zf.read(info).decode("utf-8", "replace"))
                for m in PLACEHOLDER_RE.findall(text):
                    if m not in found:
                        found.append(m)
    except (OSError, zipfile.BadZipFile, KeyError):
        pass
    return found


def _read_hint(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read().replace("\r\n", "\n").strip()
    except OSError:
        return ""
    return text[:MAX_HINT_CHARS] + (" …" if len(text) > MAX_HINT_CHARS else "")


def build(agent, label, src, dest, log):
    """Copy of <agent>/_vorlagen (src) → skill folder dest. Returns the number of templates (0 = no skill)."""
    name = skill_name(agent)
    if not SKILL_NAME_RE.match(name):
        log.warning("%s: skill name %s is not allowed – templates skipped", agent, name)
        return 0
    files, hints, general, used = [], {}, [], set()
    for dirpath, dirs, names in os.walk(src):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for fname in sorted(names):
            path = os.path.join(dirpath, fname)
            rel = os.path.relpath(path, src).replace(os.sep, "/")
            stem, ext = os.path.splitext(rel)
            ext = ext.lower()
            if fname.startswith((".", "~$")):
                continue
            if ext == ".md":
                hints[stem.lower()] = path
                continue
            if ext not in TEMPLATE_EXT:
                log.info("%s/_vorlagen/%s: file type not used as template", agent, rel)
                continue
            if os.path.getsize(path) > MAX_FILE_BYTES:
                log.warning("%s/_vorlagen/%s: larger than 10 MB – skipped", agent, rel)
                continue
            safe = "/".join(safe_segment(p) for p in rel.split("/"))
            base, sext = os.path.splitext(safe)
            n = 2
            while safe.lower() in used:
                safe = f"{base}_{n}{sext}"
                n += 1
            used.add(safe.lower())
            files.append((rel, safe, path, stem.lower(), ext))
    templates = [f for f in files if f[4] in {".docx", ".xlsx", ".pptx"}]
    if not templates:
        return 0
    matched = {f[3] for f in files}
    general = [_read_hint(p) for stem, p in sorted(hints.items()) if stem not in matched]

    os.makedirs(os.path.join(dest, "vorlagen"), exist_ok=True)
    lines = []
    for rel, safe, path, stem, ext in files:
        target = os.path.join(dest, "vorlagen", *safe.split("/"))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(path, target)
        os.chmod(target, 0o644)
        entry = f"- `vorlagen/{safe}`" + (f" (Original: {rel})" if safe != rel else "")
        if ext in {".docx", ".xlsx", ".pptx"}:
            ph = placeholders(path)
            entry += (f" – Platzhalter: {', '.join('`{{ ' + p + ' }}`' for p in ph)}" if ph
                      else " – ohne Platzhalter")
        else:
            entry += " – Bild (z. B. Logo)"
        hint = _read_hint(hints[stem]) if stem in hints else ""
        if hint:
            entry += "\n" + "\n".join("  " + ln if ln else "" for ln in hint.split("\n"))
        lines.append(entry)

    title = label or agent
    description = (f"Vorlagen des Agenten {title} (Briefe und Dokumente im Hausstil als Word, Excel oder PowerPoint). "
                   "Nutzen, wenn der Nutzer einen Brief, ein Schreiben oder ein Dokument nach Vorlage möchte.")[:1000]
    body = [
        "---",
        f"name: {name}",
        "description: " + json_str(description),
        "---",
        f"# Vorlagen – {title}",
        "",
        f"Die Dateien liegen in der Code-Ausführung unter `/mnt/data/skills/{name}/vorlagen/`.",
        "",
        "## Vorgehen",
        "1. Wähle die passende Vorlage aus der Liste unten; passt keine, frage nach oder arbeite ohne Vorlage.",
        "2. Word-Vorlage mit Platzhaltern: fülle sie mit `docxtpl` (`DocxTemplate(pfad).render({...})`); fehlt das "
        "Paket, ersetze die Platzhalter mit `python-docx` in den Absätzen, Tabellen, Kopf- und Fußzeilen.",
        "3. Vorlage ohne Platzhalter: Öffne sie mit `python-docx` (bzw. `openpyxl`, `python-pptx`), lass Briefkopf, "
        "Kopf- und Fußzeile unverändert und schreibe den Inhalt darunter.",
        "4. Speichere das Ergebnis mit einem sprechenden deutschen Dateinamen in `/mnt/data` (z. B. "
        "`Brief_Mueller_2026-11-27.docx`), deutsches Datumsformat (TT.MM.JJJJ).",
        "5. Weise darauf hin, dass es ein Entwurf ist, der vor dem Versand geprüft werden muss.",
        "",
        "## Vorlagen",
        *lines,
    ]
    if general:
        body += ["", "## Allgemeine Hinweise", *general]
    text = "\n".join(body) + "\n"
    if len(text) > MAX_BODY_CHARS:
        text = text[:MAX_BODY_CHARS] + "\n…\n"
    with open(os.path.join(dest, "SKILL.md"), "w", encoding="utf-8") as fh:
        fh.write(text)
    return len(templates)


def json_str(s):
    """YAML-safe double-quoted string."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def tree_hash(path):
    h = hashlib.sha256()
    for dirpath, dirs, names in os.walk(path):
        dirs.sort()
        for n in sorted(names):
            p = os.path.join(dirpath, n)
            h.update(os.path.relpath(p, path).encode())
            with open(p, "rb") as fh:
                h.update(hashlib.sha256(fh.read()).digest())
    return h.hexdigest()


def publish(agents, templates_dir, skills_dir, log):
    """agents: {name: label} with TEMPLATES=true. Builds each skill in skills_dir/tmp, swaps changed ones into
    skills_dir/live, removes skills of agents without templates. Returns {agent: number of templates}."""
    live, tmp = os.path.join(skills_dir, "live"), os.path.join(skills_dir, "tmp")
    os.makedirs(live, exist_ok=True)
    os.chmod(live, 0o755)
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    result, keep = {}, set()
    for agent, label in sorted(agents.items()):
        name = skill_name(agent)
        src = os.path.join(templates_dir, agent)
        new = os.path.join(tmp, name)
        os.makedirs(new)
        count = build(agent, label, src, new, log) if os.path.isdir(src) else 0
        result[agent] = count
        if not count:
            continue
        keep.add(name)
        old = os.path.join(live, name)
        if os.path.isdir(old) and tree_hash(old) == tree_hash(new):
            continue
        for dirpath, dirs, _names in os.walk(new):
            for d in dirs:
                os.chmod(os.path.join(dirpath, d), 0o755)
        os.chmod(new, 0o755)
        trash = os.path.join(tmp, f".old-{name}")
        if os.path.exists(old):
            os.rename(old, trash)
        os.rename(new, old)
        log.info("skill %s updated (%d templates)", name, count)
    for entry in os.listdir(live):
        if entry not in keep:
            shutil.rmtree(os.path.join(live, entry), ignore_errors=True)
            log.info("skill %s removed", entry)
    shutil.rmtree(tmp, ignore_errors=True)
    return result
