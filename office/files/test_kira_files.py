#!/usr/bin/env python3
"""Tests for kira_files.py (development only, needs boto3): python3 test_kira_files.py
Starts the server on HTTP and HTTPS (self-signed) and uploads like the Office MCP server does (boto3 upload_fileobj,
multipart above 8 MB), downloads with the presigned link and checks the refusals."""
import io, os, ssl, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request
from http.server import ThreadingHTTPServer

TMP = tempfile.mkdtemp()
os.environ.update(S3_ACCESS_KEY="kira", S3_SECRET_KEY="s" * 32, DATA_DIR=TMP, BUCKET="kira-files")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kira_files as kf  # noqa: E402
import boto3  # noqa: E402
from botocore.config import Config  # noqa: E402

os.makedirs(kf.OBJ_DIR, exist_ok=True)
os.makedirs(kf.MP_DIR, exist_ok=True)
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{TMP}/k.pem", "-out",
                f"{TMP}/c.pem", "-days", "1", "-subj", "/CN=localhost"], check=True, capture_output=True)
servers = {}
for scheme, port in (("http", 18080), ("https", 18443)):
    srv = ThreadingHTTPServer(("127.0.0.1", port), kf.Handler)
    if scheme == "https":
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(f"{TMP}/c.pem", f"{TMP}/k.pem")
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    servers[scheme] = f"{scheme}://localhost:{port}"
insecure = ssl._create_unverified_context()


def client(endpoint, secret="s" * 32):
    return boto3.client("s3", endpoint_url=endpoint, aws_access_key_id="kira", aws_secret_access_key=secret,
                        region_name="us-east-1", verify=False,
                        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}))


def get(url, expect):
    try:
        r = urllib.request.urlopen(url, context=insecure)
        code, body, hdr = r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        code, body, hdr = e.code, e.read(), e.headers
    assert code == expect, (code, body[:200])
    return body, hdr


def refused(fn):
    try:
        fn()
    except Exception:
        return
    raise AssertionError("accepted")


for endpoint in servers.values():
    s3 = client(endpoint)
    for size, key in ((5000, "ab12cd34_Bericht Müller & Co.docx"), (9 * 1024 * 1024, "gross.pptx")):
        data = os.urandom(size)
        s3.upload_fileobj(io.BytesIO(data), "kira-files", key, ExtraArgs={"ContentType": "application/octet-stream"})
        url = s3.generate_presigned_url("get_object", Params={"Bucket": "kira-files", "Key": key}, ExpiresIn=3600)
        body, hdr = get(url, 200)
        assert body == data and "attachment" in hdr["Content-Disposition"]
        get(url.replace("X-Amz-Signature=", "X-Amz-Signature=0"), 403)
        get(url.split("?")[0], 403)
    refused(lambda: client(endpoint, "x" * 32).put_object(Bucket="kira-files", Key="evil.txt", Body=b"x"))
    refused(lambda: s3.put_object(Bucket="kira-files", Key="../x", Body=b"x"))
    refused(lambda: s3.put_object(Bucket="other", Key="a", Body=b"x"))
    s3.put_object(Bucket="kira-files", Key="t.txt", Body=b"hi")
    url = s3.generate_presigned_url("get_object", Params={"Bucket": "kira-files", "Key": "t.txt"}, ExpiresIn=1)
    time.sleep(2)
    get(url, 403)
    print(endpoint, "ok")
print("all tests passed")
