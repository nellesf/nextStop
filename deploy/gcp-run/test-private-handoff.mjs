import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import * as fs from 'node:fs/promises';
import { handoff } from './production-private-handoff.mjs';

const { Client } = createRequire(new URL('../../backend/package.json', import.meta.url))('pg');
const base = process.argv[2];
assert(base.startsWith('/private/tmp/nsh-') || base.startsWith('/tmp/nsh-'));
const connect = async (side, user = 'nextstop_app') => {
  const c = new Client({ host: join(base, String(side)), port: 5432, user, database: 'nextstop', connectionTimeoutMillis: 5000 });
  await c.connect(); return c;
};
const vm = await connect(0), cloud = await connect(1);
const folder = join(base, 'journal');
await fs.mkdir(folder, { mode: 0o700 });
const path = join(folder, 'private-handoff.json');
const step = cmd => handoff(cmd, vm, cloud, folder, { synthetic: true });
const scalar = async (c, sql) => Object.values((await c.query(sql)).rows[0])[0];
const key = "decode(repeat('a1',32),'hex')";
const challenge = '12661389-7841-46ab-8351-64f6754c8881';
const report = '42661389-7841-46ab-8351-64f6754c8881';
const seedReport = `INSERT INTO nextstop.user_error_reports VALUES ('${report}',${key},${key},'null'::jsonb,4,
  '2026-10-30T11:34:55.123456Z','2026-11-16T11:34:55.654321Z')`;
try {
  await vm.query(`INSERT INTO nextstop.app_attest_keys(key_id_hash,public_key_pem,receipt,environment,sign_count)
      VALUES(${key},repeat('synthetic',20),decode('00ff06','hex'),'production',7);
    INSERT INTO nextstop.app_attest_challenges(challenge_id,key_id_hash,client_data,purpose,expires_at)
      VALUES('${challenge}',${key},${key},'assertion',now()+interval '2 minutes'); ${seedReport};`);
  // An initial filtered restore can contain obsolete auth rows, including a
  // challenge consumed by the VM since that backup. Only reports must be empty.
  await cloud.query(`INSERT INTO nextstop.app_attest_keys(key_id_hash,public_key_pem,receipt,environment,sign_count)
      VALUES(${key},repeat('synthetic',20),decode('00ff06','hex'),'production',4);
    INSERT INTO nextstop.app_attest_challenges(challenge_id,key_id_hash,client_data,purpose,expires_at)
      VALUES('11111111-0000-0000-0000-000000000000',${key},${key},'assertion',now()+interval '2 minutes')`);
  await cloud.query('CREATE TABLE nextstop.rehearsal_unrelated(id int); INSERT INTO nextstop.rehearsal_unrelated VALUES (1)');
  assert.equal(await step('capture'), 'prepared');
  // A PostgreSQL constraint error usually includes the whole row in DETAIL and
  // echoes the SQL text. Deliberately fail with synthetic markers and inspect
  // this disposable server's own stderr log.
  await assert.rejects(cloud.query(
    `/*SYNTHETIC-HANDOFF-SQL-MARKER*/ INSERT INTO nextstop.app_attest_keys
    (key_id_hash, public_key_pem, receipt, environment) VALUES (decode(repeat('fe',32),'hex'),$1,'x','production')`,
    ['SYNTHETIC-HANDOFF-ROW-MARKER']), e => e.code === '23514');
  const log = await fs.readFile(join(base, '1', 'log'), 'utf8');
  assert(log.includes('violates check constraint'));
  assert(!log.includes('SYNTHETIC-HANDOFF-ROW-MARKER') && !log.includes('SYNTHETIC-HANDOFF-SQL-MARKER'));
  const initial = JSON.parse(await fs.readFile(path, 'utf8'));
  await fs.writeFile(path, JSON.stringify({ ...initial, createdAt: initial.createdAt - 86400000, deadline: initial.deadline - 86400000 }));
  await assert.rejects(step('forward'), /expired/);
  await fs.writeFile(path, JSON.stringify(initial));
  await vm.query('GRANT CONNECT ON DATABASE nextstop TO nextstop_auth');
  const draining = await connect(0, 'nextstop_auth');
  try {
    await vm.query('REVOKE CONNECT ON DATABASE nextstop FROM nextstop_auth');
    await assert.rejects(step('forward'), /drained/);
  } finally { await draining.end(); }
  await cloud.query('CREATE TABLE nextstop.rehearsal_dependent(k bytea REFERENCES nextstop.app_attest_keys ON DELETE CASCADE)');
  await assert.rejects(step('forward'), /foreign key/);
  await cloud.query('DROP TABLE nextstop.rehearsal_dependent');
  const administrator = new Client({ host: join(base, '1'), user: 'postgres', database: 'postgres', port: 5432 });
  await administrator.connect();
  try {
    await administrator.query('CREATE ROLE unreviewed_login LOGIN; GRANT CONNECT ON DATABASE nextstop TO unreviewed_login');
    await assert.rejects(step('forward'), /fenced/);
    await administrator.query('REVOKE CONNECT ON DATABASE nextstop FROM unreviewed_login; DROP ROLE unreviewed_login');
  } finally { await administrator.end(); }
  await cloud.query(seedReport);
  await assert.rejects(step('forward'), /diverged/);
  await cloud.query('DELETE FROM nextstop.user_error_reports');
  assert.equal(await step('forward'), 'new');
  assert.equal(await step('forward'), 'new');
  assert.equal(await scalar(cloud, 'SELECT sign_count::int FROM nextstop.app_attest_keys'), 7);
  assert.equal(await scalar(cloud, 'SELECT challenge_id::text FROM nextstop.app_attest_challenges'), challenge);
  assert.equal(await scalar(cloud, `SELECT jsonb_typeof(payload) FROM nextstop.user_error_reports`), 'null');
  assert.equal(await scalar(cloud, `SELECT received_at='2026-10-30T11:34:55.123456Z'::timestamptz
    AND expires_at='2026-11-16T11:34:55.654321Z'::timestamptz FROM nextstop.user_error_reports`), true);

  await cloud.query(`UPDATE nextstop.app_attest_keys SET sign_count=13,revoked_at=now();
    DELETE FROM nextstop.app_attest_challenges;
    UPDATE nextstop.user_error_reports SET payload=NULL,received_at=NULL,payload_hash=NULL,payload_bytes=0;
    INSERT INTO nextstop.user_error_reports VALUES(gen_random_uuid(),${key},${key},
      '{"large":98765432109876543210}',29,now(),now()+interval '2 days')`);
  await vm.query('REVOKE INSERT ON nextstop.app_attest_keys FROM nextstop_app');
  await assert.rejects(step('rollback'), e => e.code === '42501');
  assert.equal(await scalar(vm, 'SELECT sign_count::int FROM nextstop.app_attest_keys'), 7);
  assert.equal(await scalar(vm, 'SELECT count(*)::int FROM nextstop.app_attest_challenges'), 1);
  const pending = await fs.readFile(path, 'utf8');
  assert.equal(JSON.parse(pending).phase, 'rollback-pending');
  assert(!pending.includes(report) && !pending.includes('98765432109876543210'));
  assert.equal(await step('abort'), 'new');
  await vm.query('GRANT INSERT ON nextstop.app_attest_keys TO nextstop_app');
  assert.equal(await step('rollback'), 'old');
  // Reproduce lost acknowledgement after the successful destination COMMIT.
  await fs.writeFile(path, pending);
  assert.equal(await step('rollback'), 'old');
  assert.equal(await scalar(vm, 'SELECT sign_count=13 AND revoked_at IS NOT NULL FROM nextstop.app_attest_keys'), true);
  assert.equal(await scalar(vm, 'SELECT count(*)::int FROM nextstop.app_attest_challenges'), 0);
  assert.equal(await scalar(vm, `SELECT payload IS NULL FROM nextstop.user_error_reports WHERE report_id='${report}'`), true);
  assert.equal(await scalar(vm, `SELECT payload->>'large' FROM nextstop.user_error_reports WHERE payload IS NOT NULL`), '98765432109876543210');
  await assert.rejects(step('purge-inactive'), /active writer/);
  await vm.query('GRANT CONNECT ON DATABASE nextstop TO nextstop_auth,nextstop_support');
  assert.equal(await step('purge-inactive'), 'clean');
  assert.equal(await step('purge-inactive'), 'clean');
  assert.equal(await scalar(cloud, 'SELECT count(*)::int FROM nextstop.user_error_reports'), 0);
  assert.equal(await scalar(vm, 'SELECT count(*)::int FROM nextstop.user_error_reports'), 2);
  assert.equal(await scalar(cloud, 'SELECT count(*)::int FROM nextstop.rehearsal_unrelated'), 1);
} finally { await Promise.allSettled([vm.end(), cloud.end()]); }
