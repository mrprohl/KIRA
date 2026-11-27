// lifecycle.js – deletes files in the code interpreter's storage (MinIO) after KIRA_EXPIRE_DAYS days.
// The code interpreter itself only references them for 24 hours (SESSION_CACHE_TTL) and has no expiry of its own;
// the results are stored in LibreChat. Run by setup.sh inside the file server (it has the MinIO client):
//   docker exec -e KIRA_EXPIRE_DAYS=2 codeapi-files bun -e "$(cat /opt/codeinterpreter/lifecycle.js)"
const Minio = require('minio');

const e = process.env;
const days = Number(e.KIRA_EXPIRE_DAYS || 2);
const client = new Minio.Client({
  endPoint: e.MINIO_ENDPOINT, port: Number(e.MINIO_PORT || 9000), useSSL: e.MINIO_USE_SSL === 'true',
  accessKey: e.MINIO_ACCESS_KEY, secretKey: e.MINIO_SECRET_KEY,
});
const rule = { ID: 'kira-expire', Status: 'Enabled', Filter: { Prefix: '' }, Expiration: { Days: days } };

(async () => {
  // the file server creates the bucket when it starts – wait for it
  for (let i = 0; i < 30 && !(await client.bucketExists(e.MINIO_BUCKET).catch(() => false)); i++) {
    await new Promise((r) => setTimeout(r, 2000));
  }
  await client.setBucketLifecycle(e.MINIO_BUCKET, { Rule: [rule] });
  const cfg = await client.getBucketLifecycle(e.MINIO_BUCKET);
  const set = JSON.stringify(cfg || {}).includes('kira-expire');
  console.log(set ? `lifecycle ok: files deleted after ${days} days` : 'lifecycle not set');
  process.exit(set ? 0 : 1);
})().catch((err) => { console.log(`lifecycle failed: ${err.message}`); process.exit(1); });
