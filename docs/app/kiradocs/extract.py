"""Text from documents in three stages: read the text directly → OCR (Tesseract, German) → image model via Bifrost.

extract(path, vision) returns a list of pages: {"page": n | None, "text": str, "method": "text" | "ocr" | "vision" |
"none" | "skipped-privacy" | "error"} – one entry per PDF page, one entry for other files.
"""
import base64
import csv
import io
import os
import subprocess
import tempfile

MIN_TEXT = 40          # characters below which a page counts as "no text"
MIN_CONF = 60          # mean Tesseract confidence below which OCR counts as unreliable (handwriting, poor scans)
MAX_PAGES = 300        # pages per PDF that are read at all
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".webp"}
TEXT_EXT = {".txt", ".md", ".csv", ".tsv", ".log", ".json", ".xml", ".html", ".htm"}
OFFICE_EXT = {".docx", ".xlsx", ".pptx", ".pdf"}
SUPPORTED = IMAGE_EXT | TEXT_EXT | OFFICE_EXT
GUARD_NOTICE = "⚠️ Lokal beantwortet"

VISION_PROMPT = (
    "Übertrage den Text auf diesem Bild vollständig und wörtlich, auch Handschrift, in der ursprünglichen "
    "Reihenfolge. Tabellen als einfache Zeilen mit | zwischen den Spalten. Nicht lesbare Stellen markierst du mit "
    "[unleserlich]. Enthält das Bild keinen Text (Foto, Skizze), beschreibe in zwei bis drei Sätzen, was zu sehen "
    "ist. Gib nur den Inhalt aus, keine Einleitung."
)


class Vision:
    """Image model via Bifrost (OpenAI-compatible). enabled=False: never called (OCR result is kept)."""

    def __init__(self, enabled, url, key, model, http_json, log):
        self.enabled, self.url, self.key, self.model = enabled, url.rstrip("/"), key, model
        self.http_json, self.log = http_json, log
        self.calls = 0

    def transcribe(self, png_bytes):
        """→ (text, method). Privacy guard answered locally or refused → ("", "skipped-privacy")."""
        if not self.enabled:
            return "", "none"
        self.calls += 1
        b64 = base64.b64encode(png_bytes).decode()
        body = {"model": self.model, "max_tokens": 4000, "temperature": 0,
                "messages": [{"role": "user", "content": [
                    {"type": "text", "text": VISION_PROMPT},
                    {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}}]}]}
        status, data = self.http_json("POST", f"{self.url}/chat/completions", body, self.key, timeout=300)
        if status != 200 or not isinstance(data, dict):
            msg = data.get("error") if isinstance(data, dict) else str(data)[:200]
            self.log.warning("image model: HTTP %s %s", status, msg)
            # 400/403 from the privacy guard (refused) – not sent; other errors: try again next run
            return "", ("skipped-privacy" if status in (400, 403) else "error")
        try:
            text = data["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError):
            return "", "error"
        if isinstance(text, list):
            text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
        if text.lstrip().startswith(GUARD_NOTICE):
            return "", "skipped-privacy"
        return text.strip(), "vision"


def _run(cmd, data=None, timeout=300):
    return subprocess.run(cmd, input=data, capture_output=True, timeout=timeout, check=False)


def ocr_png(png_path):
    """Tesseract (German + English) → (text, mean confidence of the words)."""
    res = _run(["tesseract", png_path, "stdout", "-l", "deu+eng", "--psm", "3", "tsv"])
    if res.returncode != 0:
        return "", 0.0
    lines, confs, words = {}, [], 0
    for row in csv.reader(io.StringIO(res.stdout.decode("utf-8", "replace")), delimiter="\t"):
        if len(row) < 12 or row[0] == "level":
            continue
        try:
            conf = float(row[10])
        except ValueError:
            continue
        word = row[11].strip()
        if conf < 0 or not word:
            continue
        words += 1
        confs.append(conf)
        key = (row[2], row[3], row[4])          # block, paragraph, line
        lines.setdefault(key, []).append(word)
    text = "\n".join(" ".join(w) for w in lines.values())
    return text, (sum(confs) / len(confs) if confs else 0.0)


def _page_png(pdf, page, max_px=2400):
    """One PDF page as PNG, long side max_px (A4 ≈ 200 dpi) – also for oversized pages (no memory blow-up)."""
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "p")
        res = _run(["pdftoppm", "-scale-to", str(max_px), "-f", str(page), "-l", str(page), "-png", "-singlefile",
                    pdf, base])
        out = base + ".png"
        if res.returncode != 0 or not os.path.exists(out):
            return None
        with open(out, "rb") as fh:
            return fh.read()


def _image_png(path):
    """Any image → PNG (max. 2400 px on the long side), for OCR and the image model."""
    from PIL import Image  # pillow
    with Image.open(path) as img:
        img.seek(0)
        img = img.convert("RGB")
        img.thumbnail((2400, 2400))
        buf = io.BytesIO()
        img.save(buf, "PNG")
        return buf.getvalue()


def _ocr_or_vision(png, vision):
    """One image (page): OCR first; unreliable or empty → image model."""
    with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
        tmp.write(png)
        tmp.flush()
        text, conf = ocr_png(tmp.name)
    if len(text) >= MIN_TEXT and conf >= MIN_CONF:
        return text, "ocr"
    vtext, method = vision.transcribe(png)
    if method == "vision":
        return vtext, "vision"
    if text and len(text) >= MIN_TEXT:
        return text, "ocr"            # weak OCR is better than nothing
    return "", method if method != "none" else ("ocr" if text else "none")


def needs_vision(png):
    """For the estimate: would this image go to the image model?"""
    with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
        tmp.write(png)
        tmp.flush()
        text, conf = ocr_png(tmp.name)
    return not (len(text) >= MIN_TEXT and conf >= MIN_CONF)


def pdf_pages(path):
    from pypdf import PdfReader
    reader = PdfReader(path)
    out = []
    for i, page in enumerate(reader.pages[:MAX_PAGES], start=1):
        try:
            out.append((i, page.extract_text() or ""))
        except Exception:  # noqa: BLE001 – broken page: treat as image
            out.append((i, ""))
    return out


def extract(path, vision):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".pdf":
        pages = []
        for no, text in pdf_pages(path):
            if len(text.strip()) >= MIN_TEXT:
                pages.append({"page": no, "text": text, "method": "text"})
                continue
            png = _page_png(path, no)
            if png is None:
                pages.append({"page": no, "text": "", "method": "error"})
                continue
            t, m = _ocr_or_vision(png, vision)
            pages.append({"page": no, "text": t, "method": m})
        return pages
    if ext in IMAGE_EXT:
        t, m = _ocr_or_vision(_image_png(path), vision)
        return [{"page": None, "text": t, "method": m}]
    if ext == ".docx":
        import docx
        d = docx.Document(path)
        parts = [p.text for p in d.paragraphs if p.text.strip()]
        for table in d.tables:
            for row in table.rows:
                parts.append(" | ".join(c.text.strip() for c in row.cells))
        return [{"page": None, "text": "\n".join(parts), "method": "text"}]
    if ext == ".xlsx":
        import openpyxl
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        parts = []
        for ws in wb.worksheets:
            parts.append(f"## {ws.title}")
            for n, row in enumerate(ws.iter_rows(values_only=True)):
                if n >= 5000:
                    break
                cells = ["" if v is None else str(v) for v in row]
                if any(cells):
                    parts.append(" | ".join(cells))
        return [{"page": None, "text": "\n".join(parts), "method": "text"}]
    if ext == ".pptx":
        from pptx import Presentation
        pres = Presentation(path)
        pages = []
        for no, slide in enumerate(pres.slides, start=1):
            texts = [sh.text_frame.text for sh in slide.shapes if getattr(sh, "has_text_frame", False)]
            pages.append({"page": no, "text": "\n".join(t for t in texts if t.strip()), "method": "text"})
        return pages
    if ext in TEXT_EXT:
        raw = open(path, "rb").read()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = raw.decode("latin-1")
        return [{"page": None, "text": text, "method": "text"}]
    return [{"page": None, "text": "", "method": "none"}]


def estimate(path):
    """Number of pages/images that would go to the image model (OCR runs, no model call)."""
    ext = os.path.splitext(path)[1].lower()
    if ext == ".pdf":
        n = 0
        for no, text in pdf_pages(path):
            if len(text.strip()) >= MIN_TEXT:
                continue
            png = _page_png(path, no)
            if png is not None and needs_vision(png):
                n += 1
        return n
    if ext in IMAGE_EXT:
        return 1 if needs_vision(_image_png(path)) else 0
    return 0
