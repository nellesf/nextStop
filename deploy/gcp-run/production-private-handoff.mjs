#!/usr/bin/env node
// Run on the old production VM only. See PRODUCTION-PRIVATE-HANDOFF.md.
import { createHmac, randomBytes } from 'node:crypto';
import * as fs from 'node:fs/promises';
import { constants, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
// The source checkout uses backend/. The verified backend OCI image has its
// locked production dependencies at /app and its migrations at /app/dist/.
const checkout = existsSync(join(root, 'backend/package.json'));
const { Client } = createRequire(join(root, checkout ? 'backend/package.json' : 'package.json'))('pg');
const migrationDirectory = join(root, checkout ? 'backend/migrations' : 'dist/migrations');
const tables = {
  app_attest_keys: ['key_id_hash', 'public_key_pem', 'receipt', 'environment', 'sign_count', 'validation_category', 'bundle_version', 'attested_at', 'last_asserted_at', 'revoked_at'],
  app_attest_challenges: ['challenge_id', 'key_id_hash', 'purpose', 'client_data', 'created_at', 'expires_at'],
  user_error_reports: ['report_id', 'deletion_token_hash', 'payload_hash', 'payload', 'payload_bytes', 'received_at', 'expires_at'],
};
const types = {
  app_attest_keys: ['bytea', 'text', 'bytea', 'text', 'bigint', 'integer', 'text', 'timestamp with time zone', 'timestamp with time zone', 'timestamp with time zone'],
  app_attest_challenges: ['uuid', 'bytea', 'text', 'bytea', 'timestamp with time zone', 'timestamp with time zone'],
  user_error_reports: ['uuid', 'bytea', 'bytea', 'jsonb', 'integer', 'timestamp with time zone', 'timestamp with time zone'],
};
const names = Object.keys(tables);
const runtimeRoles = ['nextstop_api', 'nextstop_auth', 'nextstop_support', 'nextstop_worker', 'nextstop_backup'];
const maxAge = 4 * 60 * 60 * 1000;
const project = 'nextstop-tech-staging';
const managedSocket = '/cloudsql/nextstop-tech-staging:europe-west1:nextstop-production';

function guard(condition, step) {
  if (!condition) throw new GuardError(step);
}
class GuardError extends Error { }
const equal = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const notExpired = journal => guard(Date.now() < journal.deadline, 'Handoff window expired. Keep copies fenced and resolve retention immediately.');

async function privateFile(path) {
  guard(isAbsolute(path) && await fs.realpath(path) === path, 'Expected a canonical private file.');
  const handle = await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await handle.stat();
    guard(info.isFile() && info.uid === process.getuid() && !(info.mode & 0o077) && info.size < 64 * 1024,
      'A small operator-owned private file is required.');
    return await handle.readFile('utf8');
  } finally { await handle.close(); }
}
async function saveJournal(path, state) {
  const tmp = path + '.' + randomBytes(12).toString('hex');
  const handle = await fs.open(tmp, 'wx', 0o600);
  try {
    await handle.writeFile(JSON.stringify(state));
    await handle.sync();
    await handle.close();
    await fs.rename(tmp, path);
    const directory = await fs.open(dirname(path), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } finally {
    await handle.close();
    await fs.rm(tmp, { force: true });
  }
}

async function identify(client, migrationCount) {
  await client.query('SET search_path=pg_catalog');
  // Core errors can include an offending row in DETAIL even when bind-parameter
  // logging is off. Harden a privileged VM session, or require already-safe
  // instance defaults for the restricted managed migrator.
  const requiredLogs = {
    log_statement: 'none', log_min_error_statement: 'panic', log_parameter_max_length_on_error: '0',
    log_parameter_max_length: '0', log_min_duration_statement: '-1', log_min_duration_sample: '-1',
    log_transaction_sample_rate: '0', log_error_verbosity: 'terse'
  };
  for (const [name, setting] of Object.entries(requiredLogs)) {
    const settingRow = (await client.query("SELECT current_setting($1) AS value, has_parameter_privilege(current_user,$1,'SET') AS may_set", [name])).rows[0];
    if (settingRow.value !== setting && settingRow.may_set) await client.query('SELECT set_config($1,$2,false)', [name, setting]);
    guard((await client.query('SELECT current_setting($1) AS value', [name])).rows[0].value === setting,
      'Unsafe transfer-session log setting: ' + name + '.');
  }
  const audit = (await client.query(`SELECT COALESCE(NULLIF(current_setting('pgaudit.log',true),''),'none')='none'
    AND COALESCE(current_setting('pgaudit.role',true),'')=''
    AND COALESCE(NULLIF(current_setting('pgaudit.log_parameter',true),''),'off')='off'
    AND COALESCE(NULLIF(current_setting('auto_explain.log_min_duration',true),''),'-1')='-1' AS disabled`)).rows[0];
  guard(audit.disabled, 'A logging/auditing extension may capture private rows.');
  const identity = (await client.query(`SELECT current_database() AS db, current_user AS owner,
      current_setting('server_version_num')::int / 10000 AS major, current_setting('server_encoding') AS encoding`)).rows[0];
  guard(identity.db === 'nextstop' && identity.owner === 'nextstop_app' && identity.major === 17 && identity.encoding === 'UTF8',
    'Unexpected database, operator, engine or logging policy.');
  const migrations = (await fs.readdir(migrationDirectory)).filter(n => /^\d{4}_.+\.sql$/.test(n)).sort();
  const applied = (await client.query('SELECT name FROM nextstop.schema_migrations ORDER BY name')).rows.map(r => r.name);
  guard(migrations.length >= migrationCount && equal(applied, migrations.slice(0, migrationCount)), 'Unexpected schema migration state.');
  const meta = await client.query(`SELECT c.relname, array_agg(a.attname::text ORDER BY a.attnum) AS columns,
      array_agg(format_type(a.atttypid,a.atttypmod) ORDER BY a.attnum) AS types,
      bool_and(c.relkind='r' AND c.relowner=current_user::regrole AND NOT c.relrowsecurity
        AND NOT c.relhassubclass AND NOT c.relispartition AND NOT c.relhasrules AND a.attgenerated=''
        AND a.attidentity='' AND NOT EXISTS (SELECT FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal)) AS plain
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
      WHERE n.nspname='nextstop' AND c.relname=ANY($1::text[]) GROUP BY c.relname ORDER BY c.relname`, [names]);
  guard(meta.rows.length === 3 && meta.rows.every(r => r.plain && equal(r.columns, tables[r.relname]) && equal(r.types, types[r.relname])),
    'Private table layout differs from the reviewed schema.');
  const constraints = await client.query(`SELECT c.relname, k.conname, k.contype,
      pg_get_constraintdef(k.oid, false) AS definition, k.convalidated,
      NOT EXISTS (SELECT FROM pg_index i WHERE i.indexrelid=k.conindid AND NOT (i.indisvalid AND i.indisready)) AS ready
      FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='nextstop' AND c.relname=ANY($1::text[]) ORDER BY c.relname,k.conname`, [names]);
  guard(names.every(table => constraints.rows.some(k => k.relname === table && k.contype === 'p'
    && k.definition === 'PRIMARY KEY (' + tables[table][0] + ')')) && constraints.rows.every(k => k.convalidated && k.ready),
    'Expected all private primary keys and validated constraints.');
  const inbound = await client.query(`SELECT EXISTS (SELECT FROM pg_constraint k
    JOIN pg_class c ON c.oid=k.confrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE k.contype='f' AND n.nspname='nextstop' AND c.relname=ANY($1::text[])) AS found`, [names]);
  guard(!inbound.rows[0].found, 'An incoming foreign key could affect data outside the private handoff.');
  return { columns: meta.rows, constraints: constraints.rows };
}

async function fence(client) {
  await client.query('SELECT pg_stat_clear_snapshot()');
  const result = await client.query(`SELECT
      NOT EXISTS (SELECT FROM pg_stat_activity WHERE datname=current_database()
        AND pid<>pg_backend_pid() AND COALESCE(backend_type,'client backend')='client backend') AS drained,
      NOT EXISTS (SELECT FROM pg_roles r WHERE r.rolcanlogin AND r.rolname<>current_user
        AND has_database_privilege(r.oid,current_database(),'CONNECT')
        AND NOT (r.rolname='cloudsqladmin' AND r.rolsuper)
        AND NOT (r.rolname='postgres' AND (r.rolsuper OR EXISTS (
          SELECT FROM pg_roles a WHERE a.rolname='cloudsqlsuperuser' AND pg_has_role(r.oid,a.oid,'MEMBER'))))) AS closed,
      (SELECT count(*)=4 FROM pg_roles WHERE rolname=ANY($1::text[])) AS roles`, [runtimeRoles.slice(0, 4)]);
  guard(Object.values(result.rows[0]).every(x => x === true), 'Application/worker/purge/backup writers must be fenced and sessions drained.');
}
async function begin(client, lockTables) {
  await client.query('BEGIN');
  await client.query(`SET LOCAL lock_timeout='2s'; SET LOCAL statement_timeout='60s'; SET LOCAL idle_in_transaction_session_timeout='120s';
      SET LOCAL row_security=off; SET LOCAL timezone='UTC'; SET LOCAL datestyle='ISO, YMD'; SET LOCAL bytea_output='hex'; SET LOCAL search_path=pg_catalog`);
  if (lockTables) {
    await fence(client);
    await client.query('LOCK TABLE ' + names.map(t => 'nextstop.' + t).join(',') + ' IN ACCESS EXCLUSIVE MODE');
    await fence(client);
  }
}
// Bind each row as opaque PostgreSQL JSON text. No JSON numbers, microseconds,
// bytea or tombstone NULLs pass through JavaScript's type conversions.
async function readRows(client, table, consume, alive) {
  const pairs = tables[table].map(c => `'${c}',t.${c}::text`).join(',');
  await client.query(`DECLARE private_rows NO SCROLL CURSOR FOR SELECT jsonb_build_object(${pairs})::text AS row
    FROM nextstop.${table} t ORDER BY ${tables[table][0]}`);
  for (;;) {
    alive();
    const { rows } = await client.query('FETCH FORWARD 16 FROM private_rows');
    if (!rows.length) break;
    await consume(rows.map(r => r.row));
  }
  await client.query('CLOSE private_rows');
}
async function fingerprint(client, journal, alive) {
  const result = [];
  for (const table of names) {
    const hash = createHmac('sha256', Buffer.from(journal.key, 'hex')).update(table + '\0');
    let count = 0;
    await readRows(client, table, async rows => {
      for (const row of rows) hash.update(row).update('\n');
      count += rows.length;
    }, alive);
    result.push({ count, hmac: hash.digest('hex') });
  }
  return result;
}
async function replace(source, dest, alive) {
  for (const table of names) {
    await dest.query('DELETE FROM nextstop.' + table);
    await readRows(source, table, async rows => {
      const columns = tables[table].join(',');
      const record = tables[table].map(c => c + ' text').join(',');
      const cast = tables[table].map((c, i) => c + '::' + types[table][i]).join(',');
      await dest.query(`INSERT INTO nextstop.${table} (${columns}) SELECT ${cast}
        FROM jsonb_to_recordset($1::jsonb) AS encoded(${record})`, ['[' + rows.join(',') + ']']);
    }, alive);
  }
}

export async function handoff(command, vm, cloud, directory, pin) {
  guard(['capture', 'forward', 'rollback', 'abort', 'purge-inactive'].includes(command), 'Unknown handoff operation.');
  const info = await fs.lstat(directory);
  guard(isAbsolute(directory) && await fs.realpath(directory) === directory && info.isDirectory()
    && info.uid === process.getuid() && !(info.mode & 0o077), 'A canonical operator-owned private journal directory is required.');
  const path = join(directory, 'private-handoff.json');
  // Database advisory locks serialize operators even if one accidentally supplies
  // another local directory. The expected baseline additionally protects retries.
  const clients = [vm, cloud];
  const locked = [];
  try {
    for (const client of clients) {
      guard((await client.query('SELECT pg_try_advisory_lock(1867801454, 1700307) AS held')).rows[0].held,
        'Another handoff is running.');
      locked.push(client);
    }
    const sourceLayout = await identify(vm, 15);
    guard(equal(sourceLayout, await identify(cloud, 19)), 'Private table schemas differ across endpoints.');
    let state;
    try {
      state = JSON.parse(await privateFile(path));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (command === 'capture') {
      guard(!state, 'A handoff journal already exists.');
      await begin(cloud, true);
      const createdAt = Date.now();
      state = { version: 1, pin, key: randomBytes(32).toString('hex'), createdAt, deadline: createdAt + maxAge, phase: 'prepared' };
      state.inactive = await fingerprint(cloud, state, () => notExpired(state));
      guard(state.inactive[2].count === 0, 'The freshly restored target must contain zero report rows.');
      await saveJournal(path, state);
      await cloud.query('COMMIT');
      return state.phase;
    }
    guard(state?.version === 1 && equal(state.pin, pin) && /^[a-f0-9]{64}$/.test(state.key)
      && Number.isSafeInteger(state.createdAt) && state.deadline === state.createdAt + maxAge, 'Journal absent or endpoint pins differ.');
    if (command === 'purge-inactive') {
      if (state.phase === 'clean') return 'clean';
      guard(['new', 'old', 'purge-pending'].includes(state.phase), 'Resolve any incomplete transfer before purging.');
      const liveSide = state.phase === 'purge-pending' ? state.live : state.phase;
      const [live, inactive] = liveSide === 'new' ? [cloud, vm] : [vm, cloud];
      const liveWriters = await live.query(`SELECT bool_and(has_database_privilege(rolname,current_database(),'CONNECT'))
        AND count(*)=2 AS enabled FROM pg_roles WHERE rolname IN ('nextstop_auth','nextstop_support')`);
      guard(liveWriters.rows[0].enabled, 'The recorded active writer is not enabled.');
      await begin(inactive, true);
      const actual = await fingerprint(inactive, state, () => { });
      guard(equal(actual, state.inactive) || (state.phase === 'purge-pending' && actual.every(t => !t.count)), 'Inactive private state changed.');
      state.phase = 'purge-pending';
      state.live = liveSide;
      await saveJournal(path, state);
      for (const table of names) await inactive.query('DELETE FROM nextstop.' + table);
      guard((await fingerprint(inactive, state, () => { })).every(t => !t.count), 'Inactive private rows remain.');
      await fence(inactive);
      await inactive.query('COMMIT');
      await saveJournal(path, { ...state, phase: 'clean' });
      return 'clean';
    }
    if (command === 'abort') {
      if (['old', 'new'].includes(state.phase)) return state.phase;
      if (state.phase === 'prepared') {
        await begin(cloud, true);
        guard(equal(await fingerprint(cloud, state, () => { }), state.inactive), 'Prepared destination diverged.');
        state.phase = 'old';
        await saveJournal(path, state);
        return 'old';
      }
      guard(['forward-pending', 'rollback-pending'].includes(state.phase), 'No transfer intent to abort.');
    } else {
      if ((command === 'forward' && state.phase === 'new') || (command === 'rollback' && state.phase === 'old')) return state.phase;
      guard(command === 'forward' ? ['prepared', 'forward-pending'].includes(state.phase) : ['new', 'rollback-pending'].includes(state.phase),
        'Invalid transfer sequence.');
    }
    const forward = command === 'forward' || (command === 'abort' && state.phase === 'forward-pending');
    const [source, dest] = forward ? [vm, cloud] : [cloud, vm];
    for (const client of clients) await begin(client, true);
    const expiredIntent = state.phase.endsWith('-pending') && Date.now() >= state.deadline;
    const alive = command === 'abort' || expiredIntent ? () => { } : () => notExpired(state);
    const before = await fingerprint(dest, state, alive);
    if (command === 'abort') {
      guard(equal(before, state.inactive), 'Destination has committed or diverged. Reconcile the pending transfer.');
      delete state.source;
      state.phase = forward ? 'old' : 'new';
      await saveJournal(path, state);
      return state.phase;
    }
    const expected = await fingerprint(source, state, alive);
    const pending = command + '-pending';
    if (state.phase !== pending) {
      guard(equal(before, state.inactive), 'Inactive destination diverged.');
      state.phase = pending;
      state.source = expected;
      await saveJournal(path, state);
    }
    guard(equal(expected, state.source) && (equal(before, state.inactive) || equal(before, expected)),
      'Source or destination diverged from pending transfer.');
    if (!equal(before, expected)) {
      notExpired(state);
      await replace(source, dest, () => notExpired(state));
    }
    guard(equal(await fingerprint(dest, state, alive), expected), 'Transferred state failed full-field verification.');
    await fence(source);
    await fence(dest);
    alive();
    await dest.query('COMMIT');
    await source.query('COMMIT');
    state.inactive = expected;
    delete state.source;
    state.phase = forward ? 'new' : 'old';
    await saveJournal(path, state);
    return state.phase;
  } finally {
    for (const client of locked.reverse()) {
      await client.query('ROLLBACK').catch(() => { });
      await client.query('SELECT pg_advisory_unlock(1867801454, 1700307)').catch(() => { });
    }
  }
}

async function runCLI() {
  guard(process.platform === 'linux' && process.argv.length === 5, 'Use the documented Linux production VM operator context.');
  const [command, configuration, directory] = process.argv.slice(2);
  const cfg = JSON.parse(await privateFile(configuration));
  const meta = async name => {
    const response = await fetch('http://169.254.169.254/computeMetadata/v1/' + name, {
      headers: { 'Metadata-Flavor': 'Google' }, redirect: 'error', signal: AbortSignal.timeout(3000)
    });
    guard(response.ok && response.headers.get('metadata-flavor') === 'Google', 'GCE host identity unavailable.');
    return (await response.text()).trim();
  };
  guard(await meta('project/project-id') === project && await meta('instance/name') === 'nextstop-backend'
    && (await meta('instance/zone')).endsWith('/zones/europe-west3-a')
    && /^\d{1,24}$/.test(cfg.vmInstanceId) && await meta('instance/id') === cfg.vmInstanceId,
    'Unexpected production VM identity.');
  guard(/^\d{1,24}$/.test(cfg.vmDatabaseSystemId) && /^\d{1,24}$/.test(cfg.cloudDatabaseSystemId)
    && cfg.vmDatabaseSystemId !== cfg.cloudDatabaseSystemId && /^\d{1,24}$/.test(cfg.filteredRestoreGeneration),
    'Independently verified VM database and filtered restore pins are required.');
  const token = JSON.parse(await meta('instance/service-accounts/default/token')).access_token;
  const instance = await fetch('https://sqladmin.googleapis.com/sql/v1beta4/projects/' + project + '/instances/nextstop-production', {
    headers: { Authorization: 'Bearer ' + token }, redirect: 'error', signal: AbortSignal.timeout(10000)
  });
  guard(instance.ok, 'Cannot verify production Cloud SQL identity.');
  const current = await instance.json();
  guard(current.connectionName === managedSocket.split('/').at(-1) && current.state === 'RUNNABLE'
    && typeof cfg.cloudCreateTime === 'string' && current.createTime === cfg.cloudCreateTime
    && current.settings?.connectorEnforcement === 'REQUIRED'
    && !current.settings?.insightsConfig?.queryInsightsEnabled
    && !(current.settings?.databaseFlags || []).some(f => f.name === 'cloudsql.enable_pgaudit' && !['off', 'false'].includes(f.value)),
    'Unexpected managed instance, connector or query-audit policy.');
  guard((await fs.stat(managedSocket + '/.s.PGSQL.5432')).isSocket(), 'Production Cloud SQL Auth Proxy socket is absent.');
  const options = { port: 5432, database: 'nextstop', user: 'nextstop_app', application_name: 'nextstop-private-handoff', ssl: false, connectionTimeoutMillis: 5000 };
  const vm = new Client({ ...options, host: '127.0.0.1', password: (await privateFile(cfg.vmPasswordFile)).trimEnd() });
  const cloud = new Client({ ...options, host: managedSocket, password: (await privateFile(cfg.cloudPasswordFile)).trimEnd() });
  for (const client of [vm, cloud]) client.on('error', () => { });
  try {
    await vm.connect(); await cloud.connect();
    guard((await vm.query('SELECT system_identifier::text AS id FROM pg_control_system()')).rows[0].id === cfg.vmDatabaseSystemId, 'VM database identity mismatch.');
    guard((await cloud.query('SELECT system_identifier::text AS id FROM pg_control_system()')).rows[0].id === cfg.cloudDatabaseSystemId, 'Cloud SQL database identity mismatch.');
    const pin = {
      project, vmId: cfg.vmInstanceId, vmDatabaseSystemId: cfg.vmDatabaseSystemId,
      cloudDatabaseSystemId: cfg.cloudDatabaseSystemId, managedSocket, cloudCreateTime: cfg.cloudCreateTime,
      filteredRestoreGeneration: cfg.filteredRestoreGeneration
    };
    console.log(JSON.stringify({ privateHandoff: await handoff(command, vm, cloud, directory, pin) }));
  } finally { await Promise.allSettled([vm.end(), cloud.end()]); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  runCLI().catch(e => { console.error(e instanceof GuardError ? e.message : 'Private handoff failed. Keep writers fenced and inspect the transfer prerequisites.'); process.exitCode = 1; });
}
