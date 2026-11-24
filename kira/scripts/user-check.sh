#!/usr/bin/env bash
# ============================================================================
# user-check.sh – which role, agent list and builder profile a LibreChat user gets (read-only)
#   bash /opt/kira/scripts/user-check.sh <e-mail or part of it>
#   Shows: role sync settings, the user's role, the agents of that role (modelSpecs.list), the builder
#   profile (builder-sync.py) and role-sync lines from the LibreChat log of the last 30 minutes.
#   Changes nothing. Typical finding: role USER = no matching Keycloak group at the last login
#   (fix the group in Keycloak, then log out and in again).
# ============================================================================
set -uo pipefail
KIRA_DIR=/opt/kira
[ "$(id -u)" = 0 ] || { echo "Error: please run as root." >&2; exit 1; }
[ -n "${1:-}" ] || { echo "Usage: $0 <e-mail or part of it>" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' librechat 2>/dev/null)" = "true" ] \
  || { echo "Error: LibreChat is not running." >&2; exit 1; }

echo "== Role sync (env/librechat.env) =="
grep -E '^OPENID_(ROLE_SYNC_ENABLED|ROLE_SYNC_ROLE_PRIORITY|REQUIRED_ROLE|ADMIN_ROLE)=' "$KIRA_DIR/env/librechat.env"
echo

# the search term travels on stdin in front of the script (JSON-quoted, no shell expansion inside node)
{ printf "'use strict';\nprocess.env.KIRA_Q = %s;\n" "$(python3 -I -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1")"
  cat <<'JS'
require('module-alias')({ base: '/app/api' });
const { connectDb } = require('~/db');
const mongoose = require('mongoose');
(async () => {
  await connectDb();
  const M = mongoose.models;
  const q = process.env.KIRA_Q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const users = await M.User.find({ $or: [{ email: { $regex: q, $options: 'i' } }, { username: { $regex: q, $options: 'i' } }] })
    .select('email username role provider createdAt').limit(10).lean();
  if (!users.length) {
    console.log('No user found (has the person logged in to KIRA at least once?).');
    process.exit(0);
  }
  const show = (c) => {
    const o = c.overrides || {};
    const list = (o.modelSpecs && o.modelSpecs.list) || null;
    console.log(`    priority ${c.priority}, active ${c.isActive !== false}`);
    console.log(`    agents (modelSpecs.list): ${list ? list.map((s) => s.label || s.name).join(', ') || '(empty)' : '(not set)'}`);
    if (o.modelSpecs) console.log(`    modelSpecs other: ${JSON.stringify({ ...o.modelSpecs, list: undefined })}`);
    if (o.endpoints) {
      const custom = (o.endpoints.custom || []).map((e) => `${e.name}: ${((e.models || {}).default || []).join(', ')}`);
      console.log(`    providers: ${JSON.stringify((o.endpoints.agents || {}).allowedProviders || [])}`);
      if (custom.length) console.log(`    models: ${custom.join(' | ')}`);
    }
    if (c.tombstones && c.tombstones.length) console.log(`    hidden for this role: ${c.tombstones.join(', ')}`);
  };
  for (const u of users) {
    console.log(`== User ${u.email} (${u.username || '-'}) ==`);
    console.log(`  role: ${u.role}   login: ${u.provider}   first login: ${u.createdAt && u.createdAt.toISOString()}`);
    const role = await M.Role.findOne({ name: u.role }).lean();
    console.log(`  role exists: ${!!role}   agent permissions: ${role ? JSON.stringify(role.permissions && role.permissions.AGENTS) : '-'}`);
    for (const c of await M.Config.find({ principalType: 'role', principalId: u.role }).lean()) {
      console.log(`  role profile "${u.role}":`);
      show(c);
    }
    for (const c of await M.Config.find({ principalType: 'user', principalId: String(u._id) }).lean()) {
      console.log('  user profile (builder-sync.py):');
      show(c);
    }
    if (u.role === 'USER') {
      console.log('  -> role USER: no matching Keycloak group at the last login – check the groups, then log out and in.');
    }
  }
  process.exit(0);
})().catch((e) => { console.error(`Error: ${e.message}`); process.exit(1); });
JS
} | docker exec -i -w /app librechat node - 2>&1 | grep -v -E '^[0-9-]+ [0-9:]+ info: (Mongo Connection options|\{|  "bufferCommands"|\})' | grep -v -E '^\}$|^  "bufferCommands": false$'

echo
echo "== LibreChat log (role sync / login, last 30 minutes) =="
docker logs --since 30m librechat 2>&1 | grep -iE 'openidRoleSync|role sync|required role|openidStrategy' | tail -15 \
  || echo "(nothing)"
