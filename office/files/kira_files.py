#!/usr/bin/env python3
"""
kira-files – the smallest S3 service KIRA needs: documents of the Office MCP server are uploaded here and handed to
the user as a signed, time-limited download link (presigned URL). Standard library only.

What it speaks (path style, one bucket):
  PUT  /<bucket>/<key>                        upload (AWS Signature V4 in the Authorization header)
  POST /<bucket>/<key>?uploads                 start a multipart upload   (boto3 uses it above 8 MB)
  PUT  /<bucket>/<key>?partNumber=N&uploadId=  upload a part
  POST /<bucket>/<key>?uploadId=               complete the multipart upload
  DELETE /<bucket>/<key>?uploadId=             abort it
  GET/HEAD /<bucket>/<key>?X-Amz-…             download with a presigned URL (Signature V4 in the query)
Everything else is refused. Files are deleted after FILE_TTL_HOURS.

The signature covers the Host header: uploads and links are signed for the public KIRA domain, Caddy passes the
Host header through unchanged. Environment: S3_ACCESS_KEY, S3_SECRET_KEY, BUCKET, DATA_DIR, FILE_TTL_HOURS, MAX_MB,
PORT, REGION.
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import sys
import threading
import time
from datetime import datetime, timezone
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, quote, unquote

ACCESS_KEY = os.environ.get("S3_ACCESS_KEY", "")
SECRET_KEY = os.environ.get("S3_SECRET_KEY", "")
BUCKET = os.environ.get("BUCKET", "kira-files")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
TTL_HOURS = float(os.environ.get("FILE_TTL_HOURS", "24"))
MAX_BYTES = int(float(os.environ.get("MAX_MB", "100")) * 1024 * 1024)
PORT = int(os.environ.get("PORT", "8080"))
REGION = os.environ.get("REGION", "us-east-1")
CLOCK_SKEW = 15 * 60          # seconds a header signature may be off
MAX_PRESIGN = 7 * 24 * 3600   # longest link S3 allows

OBJ_DIR = os.path.join(DATA_DIR, "objects")
MP_DIR = os.path.join(DATA_DIR, "multipart")
KEY_BAD = re.compile(r"[/\\\x00-\x1f\x7f]")


class S3Error(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


# ---------------------------------------------------------------- Signature V4
def _hmac(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def signing_key(secret, date, region, service="s3"):
    k = _hmac(("AWS4" + secret).encode("utf-8"), date)
    k = _hmac(k, region)
    k = _hmac(k, service)
    return _hmac(k, "aws4_request")


def uri_encode(s, safe="-_.~"):
    return quote(s, safe=safe)


def canonical_query(raw_query, drop=()):
    pairs = [(k, v) for k, v in parse_qsl(raw_query, keep_blank_values=True) if k not in drop]
    pairs = [(uri_encode(k), uri_encode(v)) for k, v in pairs]
    return "&".join(f"{k}={v}" for k, v in sorted(pairs))


def canonical_headers(headers, signed):
    lines = []
    for name in signed:
        value = headers.get(name)
        if value is None:
            raise S3Error(403, "AccessDenied", f"signed header {name} missing")
        lines.append(f"{name}:{' '.join(value.strip().split())}\n")
    return "".join(lines)


def verify(method, raw_path, raw_query, headers, credential, amz_date, signed_headers, signature, payload_hash,
           drop_query=()):
    parts = credential.split("/")
    if len(parts) != 5 or parts[4] != "aws4_request" or parts[3] != "s3":
        raise S3Error(403, "AccessDenied", "invalid credential scope")
    access, date, region = parts[0], parts[1], parts[2]
    if not hmac.compare_digest(access, ACCESS_KEY):
        raise S3Error(403, "InvalidAccessKeyId", "unknown access key")
    if not amz_date.startswith(date):
        raise S3Error(403, "AccessDenied", "date mismatch")
    signed = signed_headers.split(";")
    canonical = "\n".join([method, raw_path, canonical_query(raw_query, drop_query),
                           canonical_headers(headers, signed), signed_headers, payload_hash])
    scope = f"{date}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    expected = hmac.new(signing_key(SECRET_KEY, date, region), to_sign.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature):
        raise S3Error(403, "SignatureDoesNotMatch", "signature does not match")


def parse_amz_date(value):
    try:
        return datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        raise S3Error(403, "AccessDenied", "invalid X-Amz-Date")


# ---------------------------------------------------------------- aws-chunked bodies (botocore checksums)
def decode_aws_chunked(body):
    out, pos = bytearray(), 0
    while True:
        end = body.find(b"\r\n", pos)
        if end < 0:
            raise S3Error(400, "IncompleteBody", "invalid chunked body")
        size = int(body[pos:end].split(b";", 1)[0], 16)
        pos = end + 2
        if size == 0:
            return bytes(out)          # trailers (checksums) follow – not needed
        out += body[pos:pos + size]
        pos += size + 2


# ---------------------------------------------------------------- storage
def object_path(key):
    if not key or len(key.encode("utf-8")) > 255 or key.startswith(".") or KEY_BAD.search(key):
        raise S3Error(400, "InvalidArgument", "key not allowed")
    return os.path.join(OBJ_DIR, key)


def write_atomic(path, data, meta):
    tmp = f"{path}.tmp-{secrets.token_hex(4)}"
    with open(tmp, "wb") as fh:
        fh.write(data)
    with open(path + ".json.tmp", "w", encoding="utf-8") as fh:
        json.dump(meta, fh)
    os.replace(tmp, path)
    os.replace(path + ".json.tmp", path + ".json")


def cleanup_loop():
    while True:
        limit = time.time() - TTL_HOURS * 3600
        for base in (OBJ_DIR, MP_DIR):
            for name in os.listdir(base):
                p = os.path.join(base, name)
                try:
                    if os.path.getmtime(p) < limit:
                        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
                except OSError:
                    pass
        time.sleep(600)


def xml(tag, **fields):
    inner = "".join(f"<{k}>{v}</{k}>" for k, v in fields.items())
    ns = "" if tag == "Error" else ' xmlns="http://s3.amazonaws.com/doc/2006-03-01/"'   # S3 errors have none
    return f'<?xml version="1.0" encoding="UTF-8"?>\n<{tag}{ns}>{inner}</{tag}>'.encode()


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "kira-files"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):      # no URLs (they contain signatures) – method and status only
        pass

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)
        sys.stdout.write(f"{self.command} {status}\n")

    def _error(self, err):
        # the request body may not have been read – close the connection so it is not taken for the next request
        self.close_connection = True
        self._send(err.status, xml("Error", Code=err.code, Message=err.message),
                   {"Content-Type": "application/xml", "Connection": "close"})

    def _split(self):
        raw_path, _, raw_query = self.path.partition("?")
        parts = raw_path.split("/", 2)
        if len(parts) < 3 or parts[1] != BUCKET or not parts[2]:
            raise S3Error(404, "NoSuchKey", "not found")
        return raw_path, raw_query, unquote(parts[2])

    def _headers(self):
        return {k.lower(): v for k, v in self.headers.items()}

    def _body(self):
        limit = MAX_BYTES + 1024 * 1024
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():   # botocore over HTTPS
            data = bytearray()
            while True:
                size = int(self.rfile.readline(1024).split(b";", 1)[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline(8192) not in (b"\r\n", b"\n", b""):
                        pass                                                    # HTTP trailers
                    return bytes(data)
                if len(data) + size > limit:
                    raise S3Error(400, "EntityTooLarge", "file too large")
                data += self.rfile.read(size)
                self.rfile.readline(16)
        length = int(self.headers.get("Content-Length") or 0)
        if length > limit:
            raise S3Error(400, "EntityTooLarge", "file too large")
        return self.rfile.read(length) if length else b""

    def _auth_header(self, raw_path, raw_query, body):
        h = self._headers()
        m = re.match(r"AWS4-HMAC-SHA256 Credential=([^,\s]+),\s*SignedHeaders=([^,\s]+),\s*Signature=([0-9a-f]{64})",
                     h.get("authorization", ""))
        if not m:
            raise S3Error(403, "AccessDenied", "signature missing")
        amz_date = h.get("x-amz-date", "")
        if abs(time.time() - parse_amz_date(amz_date)) > CLOCK_SKEW:
            raise S3Error(403, "RequestTimeTooSkewed", "request time too skewed")
        payload = h.get("x-amz-content-sha256", "")
        if not payload:
            raise S3Error(403, "AccessDenied", "x-amz-content-sha256 missing")
        verify(self.command, raw_path, raw_query, h, m.group(1), amz_date, m.group(2), m.group(3), payload)
        if payload.startswith("STREAMING-") or "aws-chunked" in h.get("content-encoding", ""):
            body = decode_aws_chunked(body)
        elif payload != "UNSIGNED-PAYLOAD" and not hmac.compare_digest(hashlib.sha256(body).hexdigest(), payload):
            raise S3Error(400, "XAmzContentSHA256Mismatch", "payload hash mismatch")
        if len(body) > MAX_BYTES:
            raise S3Error(400, "EntityTooLarge", "file too large")
        return body

    def do_PUT(self):
        try:
            raw_path, raw_query, key = self._split()
            q = dict(parse_qsl(raw_query, keep_blank_values=True))
            body = self._auth_header(raw_path, raw_query, self._body())
            etag = '"' + hashlib.md5(body).hexdigest() + '"'
            if "uploadId" in q:                                   # multipart part
                d = os.path.join(MP_DIR, re.sub(r"[^A-Za-z0-9]", "", q["uploadId"]))
                n = int(q.get("partNumber", "0"))
                if not os.path.isdir(d) or not 1 <= n <= 10000:
                    raise S3Error(404, "NoSuchUpload", "unknown upload")
                with open(os.path.join(d, f"{n:05d}"), "wb") as fh:
                    fh.write(body)
            else:
                path = object_path(key)
                ctype = self.headers.get("Content-Type") or "application/octet-stream"
                write_atomic(path, body, {"content_type": ctype})
            self._send(200, b"", {"ETag": etag})
        except S3Error as e:
            self._error(e)

    def do_POST(self):
        try:
            raw_path, raw_query, key = self._split()
            q = dict(parse_qsl(raw_query, keep_blank_values=True))
            body = self._auth_header(raw_path, raw_query, self._body())
            if "uploads" in q:
                object_path(key)
                upload_id = secrets.token_hex(16)
                d = os.path.join(MP_DIR, upload_id)
                os.makedirs(d)
                with open(os.path.join(d, "meta.json"), "w", encoding="utf-8") as fh:
                    json.dump({"key": key, "content_type": self.headers.get("Content-Type")
                               or "application/octet-stream"}, fh)
                self._send(200, xml("InitiateMultipartUploadResult", Bucket=BUCKET, Key=key, UploadId=upload_id),
                           {"Content-Type": "application/xml"})
            elif "uploadId" in q:
                d = os.path.join(MP_DIR, re.sub(r"[^A-Za-z0-9]", "", q["uploadId"]))
                if not os.path.isdir(d):
                    raise S3Error(404, "NoSuchUpload", "unknown upload")
                with open(os.path.join(d, "meta.json"), encoding="utf-8") as fh:
                    meta = json.load(fh)
                wanted = [int(n) for n in re.findall(rb"<PartNumber>(\d+)</PartNumber>", body)]
                data = bytearray()
                for n in sorted(wanted):
                    with open(os.path.join(d, f"{n:05d}"), "rb") as fh:
                        data += fh.read()
                    if len(data) > MAX_BYTES:
                        raise S3Error(400, "EntityTooLarge", "file too large")
                write_atomic(object_path(meta["key"]), bytes(data), {"content_type": meta["content_type"]})
                shutil.rmtree(d, ignore_errors=True)
                etag = '"' + hashlib.md5(bytes(data)).hexdigest() + f'-{len(wanted)}"'
                self._send(200, xml("CompleteMultipartUploadResult", Bucket=BUCKET, Key=key, ETag=etag),
                           {"Content-Type": "application/xml"})
            else:
                raise S3Error(405, "MethodNotAllowed", "not supported")
        except S3Error as e:
            self._error(e)

    def do_DELETE(self):
        try:
            raw_path, raw_query, key = self._split()
            q = dict(parse_qsl(raw_query, keep_blank_values=True))
            self._auth_header(raw_path, raw_query, self._body())
            if "uploadId" not in q:
                raise S3Error(405, "MethodNotAllowed", "not supported")
            shutil.rmtree(os.path.join(MP_DIR, re.sub(r"[^A-Za-z0-9]", "", q["uploadId"])), ignore_errors=True)
            self._send(204)
        except S3Error as e:
            self._error(e)

    def do_GET(self):
        try:
            raw_path, raw_query, key = self._split()
            q = dict(parse_qsl(raw_query, keep_blank_values=True))
            if q.get("X-Amz-Algorithm") != "AWS4-HMAC-SHA256" or "X-Amz-Signature" not in q:
                raise S3Error(403, "AccessDenied", "link without signature")
            amz_date = q.get("X-Amz-Date", "")
            start = parse_amz_date(amz_date)
            expires = int(q.get("X-Amz-Expires", "0"))
            if not 0 < expires <= MAX_PRESIGN or time.time() > start + expires or time.time() < start - CLOCK_SKEW:
                raise S3Error(403, "AccessDenied", "Der Download-Link ist abgelaufen.")
            verify("GET", raw_path, raw_query, self._headers(), q.get("X-Amz-Credential", ""), amz_date,
                   q.get("X-Amz-SignedHeaders", ""), q["X-Amz-Signature"], "UNSIGNED-PAYLOAD",
                   drop_query=("X-Amz-Signature",))
            path = object_path(key)
            if not os.path.isfile(path):
                raise S3Error(404, "NoSuchKey", "Die Datei gibt es nicht mehr (Download-Links gelten nur begrenzt).")
            with open(path + ".json", encoding="utf-8") as fh:
                meta = json.load(fh)
            with open(path, "rb") as fh:
                data = fh.read()
            name = re.sub(r"^[0-9a-f]{8}_", "", key)
            self._send(200, data, {
                "Content-Type": meta.get("content_type", "application/octet-stream"),
                "Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}",
                "Last-Modified": formatdate(os.path.getmtime(path), usegmt=True),
                "Cache-Control": "private, no-store",
                "X-Content-Type-Options": "nosniff",
            })
        except S3Error as e:
            self._error(e)

    do_HEAD = do_GET


def main():
    if not ACCESS_KEY or not SECRET_KEY or len(SECRET_KEY) < 20:
        sys.exit("kira-files: S3_ACCESS_KEY and S3_SECRET_KEY (at least 20 characters) are required.")
    if len(sys.argv) > 1 and sys.argv[1] == "healthcheck":
        import urllib.request
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/healthz", timeout=3)
        except Exception as e:      # 404 means: server answers
            sys.exit(0 if getattr(e, "code", None) == 404 else 1)
        sys.exit(0)
    os.makedirs(OBJ_DIR, exist_ok=True)
    os.makedirs(MP_DIR, exist_ok=True)
    if os.getuid() == 0:          # started as root only to own the volume – continue as RUN_AS_UID
        uid = int(os.environ.get("RUN_AS_UID", "10001"))
        for d in (DATA_DIR, OBJ_DIR, MP_DIR):
            os.chown(d, uid, uid)
        os.setgroups([])
        os.setgid(uid)
        os.setuid(uid)
    threading.Thread(target=cleanup_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    print(f"kira-files: bucket {BUCKET}, links up to {TTL_HOURS:g} h, max {MAX_BYTES // 1048576} MB, port {PORT}",
          flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
