'use strict';
/**
 * builder-sync.js – personal LibreChat profiles for builders (BUILDER_GROUP + model groups) and admins
 * (runs INSIDE the librechat container, only via scripts/builder-sync.py):
 *   (payload line + this file) | docker exec -i -w /app librechat node -   (KIRA_BUILDERS = base64 JSON)
 *
 * Payload: { priority, users: [{ sub, groups, overrides }] }
 *   sub        Keycloak user ID (= openidId of the LibreChat user)
 *   overrides  user profile (builder visible, allowed providers, own agents selectable)
 *
 * Profiles are user configs with the priority `priority` – this marks them as managed by KIRA:
 * profiles with this priority whose user is no longer a builder are removed; user configs with
 * another priority (created by an admin) are never touched.
 * Last output line: KIRA_RESULT {"applied", "removed", "unchanged", "pending": [sub]}
 */

const USER_TYPE = 'user';
const USER_MODEL = 'User';

/** JSON with sorted keys – to compare stored and wanted profiles. */
function canonical(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonical).join(',')}]`;
  }
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

async function sync(m, db, payload, log) {
  const priority = payload.priority;
  if (typeof priority !== 'number') {
    throw new Error('payload without priority');
  }
  const result = { applied: 0, removed: 0, unchanged: 0, pending: [] };
  const wanted = new Map();
  for (const u of payload.users || []) {
    const user = await db.findUserBySub(u.sub);
    if (!user) {
      result.pending.push(u.sub);
      continue;
    }
    wanted.set(String(user._id), u);
  }
  for (const cfg of await db.findManaged(priority)) {
    const id = String(cfg.principalId);
    if (!wanted.has(id)) {
      await m.deleteConfig(USER_TYPE, id);
      result.removed += 1;
      log(`user ${id}: builder profile removed (no longer a builder)`);
    }
  }
  for (const [id, u] of wanted) {
    const existing = await db.findUserConfig(id);
    if (existing && existing.priority !== priority) {
      log(`user ${id}: has its own profile (priority ${existing.priority}) – not changed by KIRA`);
      result.unchanged += 1;
      continue;
    }
    if (existing && existing.isActive !== false && canonical(existing.overrides || {}) === canonical(u.overrides)) {
      result.unchanged += 1;
      continue;
    }
    await m.upsertConfig(USER_TYPE, id, USER_MODEL, u.overrides, priority);
    result.applied += 1;
    log(`user ${id}: builder profile set (${u.groups.join(', ')})`);
  }
  return result;
}

async function main() {
  require('module-alias')({ base: '/app/api' });
  // '~/db' registers the mongoose models (as the LibreChat server does) – see agent-groups.js
  const { connectDb } = require('~/db');
  const m = require('~/models');
  const mongoose = require('mongoose');
  const raw = process.env.KIRA_BUILDERS;
  if (!raw) {
    throw new Error('KIRA_BUILDERS is missing');
  }
  const payload = JSON.parse(Buffer.from(raw, 'base64').toString('utf8'));
  await connectDb();
  const db = {
    findUserBySub: (sub) => mongoose.models.User.findOne({ openidId: sub }).select('_id').lean(),
    findManaged: (priority) =>
      mongoose.models.Config.find({ principalType: USER_TYPE, priority }).select('principalId').lean(),
    findUserConfig: (id) =>
      mongoose.models.Config.findOne({ principalType: USER_TYPE, principalId: id })
        .select('priority overrides isActive')
        .lean(),
  };
  const result = await sync(m, db, payload, (line) => console.log(`  ${line}`));
  console.log(`KIRA_RESULT ${JSON.stringify(result)}`);
}

// run via stdin (node -): require.main is undefined there, so only the test switch decides
if (!process.env.KIRA_TEST) {
  main()
    .then(() => process.exit(0))
    .catch((err) => {
      console.error(`Error: ${err && err.message ? err.message : err}`);
      process.exit(1);
    });
}

module.exports = { sync, canonical };
