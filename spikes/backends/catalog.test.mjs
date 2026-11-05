import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { createGateway } from '../google-cloud/gateway.mjs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHmac, randomBytes } from 'node:crypto';
import { runClientMatrix } from './client-matrix.mjs';

const exec = promisify(execFile);

test('real PostgreSQL enforces membership, revisions, and audit atomicity', async (t) => {
  const connectionString = process.env.BOOKALOG_TEST_DATABASE_URL;
  assert.ok(connectionString, 'Run via script/test.sh to create an isolated database.');
  const db = new pg.Client({ connectionString });
  await db.connect();
  t.after(() => db.end());
  await db.query('CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN');
  await db.query(await readFile(
    new URL('./catalog.sql', import.meta.url),
    'utf8',
  ));
  const { editions } = JSON.parse(await readFile(new URL('../fixtures/generated/catalog.json', import.meta.url)));
  await db.query(`INSERT INTO works SELECT DISTINCT ON (value->>'work_id')
    (value->>'work_id')::uuid, value->>'title' FROM jsonb_array_elements($1::jsonb)`, [JSON.stringify(editions)]);
  await db.query(`INSERT INTO editions SELECT (value->>'id')::uuid, (value->>'work_id')::uuid, value
    FROM jsonb_array_elements($1::jsonb)`, [JSON.stringify(editions)]);
  await db.query(`INSERT INTO memberships (user_id, role) VALUES
    ('test-editor', 'editor'), ('test-viewer', 'viewer'), ('test-administrator', 'administrator')`);

  const asUser = async (user, fn) => {
    await db.query('BEGIN');
    try {
      await db.query('SET LOCAL ROLE catalog_client');
      await db.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: user })]);
      const result = await fn();
      await db.query('COMMIT');
      return result;
    } catch (error) {
      await db.query('ROLLBACK');
      throw error;
    }
  };
  const count = async () => Number((await db.query('SELECT count(*) FROM editions')).rows[0].count);
  const update = (revision, title) => db.query('SELECT update_edition_title($1, $2, $3) AS record', [editions[0].id, revision, title]);

  await t.test('approved viewers read all records; unapproved identities read none', async () => {
    assert.equal(await asUser('test-viewer', count), 5000);
    assert.equal(await asUser('unapproved', count), 0);
    assert.equal(await asUser('', count), 0);
  });
  await t.test('viewers and unapproved identities cannot call the write operation', async () => {
    for (const user of ['test-viewer', 'unapproved']) {
      await assert.rejects(asUser(user, () => update(1, 'Denied')), { code: '42501' });
    }
  });
  await t.test('direct writes cannot bypass the operation or change memberships/audit', async () => {
    for (const query of [
      "UPDATE editions SET record = record || '{\"revision\": 99}'::jsonb",
      "UPDATE memberships SET role = 'administrator'",
      'DELETE FROM audit_events',
    ]) {
      await assert.rejects(asUser('test-editor', () => db.query(query)), { code: '42501' });
    }
  });
  await t.test('a successful write advances revision and records one immutable audit event', async () => {
    const result = await asUser('test-editor', () => update(1, 'A revised synthetic title'));
    assert.equal(result.rows[0].record.revision, 2);
    assert.equal(result.rows[0].record.title, 'A revised synthetic title');
    const audit = await db.query('SELECT * FROM audit_events');
    assert.equal(audit.rows.length, 1);
    assert.equal(audit.rows[0].actor_id, 'test-editor');
    assert.equal(audit.rows[0].before_record.revision, 1);
    assert.equal(audit.rows[0].after_record.revision, 2);
  });
  await t.test('stale and invalid writes neither overwrite nor create audit events', async () => {
    await assert.rejects(asUser('test-editor', () => update(1, 'Stale draft')), { code: 'PT409' });
    await assert.rejects(asUser('test-editor', () => update(null, 'No revision')), { code: 'PT409' });
    await assert.rejects(asUser('test-editor', () => update(2, '  ')), { code: '22023' });
    assert.equal(Number((await db.query('SELECT count(*) FROM audit_events')).rows[0].count), 1);
  });
  await t.test('a database failure rolls back both the edition and its audit', async () => {
    await db.query("ALTER TABLE audit_events ADD CONSTRAINT deliberately_fail CHECK (actor_id <> 'test-administrator')");
    await assert.rejects(asUser('test-administrator', () => update(2, 'Must roll back')), { code: '23514' });
    const record = (await db.query('SELECT record FROM editions WHERE id=$1', [editions[0].id])).rows[0].record;
    assert.equal(record.revision, 2);
    assert.equal(record.title, 'A revised synthetic title');
    await db.query('ALTER TABLE audit_events DROP CONSTRAINT deliberately_fail');
  });
  await t.test('revocation applies even when the caller still has the same identity claim', async () => {
    await db.query("UPDATE memberships SET active=false WHERE user_id='test-editor'");
    assert.equal(await asUser('test-editor', count), 0);
    await assert.rejects(asUser('test-editor', () => update(2, 'Revoked')), { code: '42501' });
  });
  await t.test('Google Cloud HTTP boundary validates auth, preserves roles, and maps conflicts', async () => {
    const pool = new pg.Pool({ connectionString });
    const server = createGateway({
      pool,
      verifyToken: async (token) => {
        if (!['test-viewer', 'test-administrator', 'unapproved'].includes(token)) throw new Error('Invalid test token');
        return { uid: token };
      },
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}`;
    try {
      assert.equal((await fetch(`${url}/editions`)).status, 401);
      assert.equal((await fetch(`${url}/editions`, { headers: { authorization: 'Bearer invalid' } })).status, 401);
      assert.equal((await fetch(`${url}/editions`, { headers: { authorization: 'Bearer unapproved' } })).status, 403);
      const read = await fetch(`${url}/editions`, { headers: { authorization: 'Bearer test-viewer' } });
      assert.equal((await read.json()).editions.length, 5000);
      const edit = (token, revision, title) => fetch(`${url}/editions/${editions[0].id}`, {
        method: 'PATCH',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify({ expected_revision: revision, title }),
      });
      assert.equal((await edit('test-viewer', 2, 'Denied')).status, 403);
      assert.equal((await edit('test-administrator', 2, 'HTTP write')).status, 200);
      assert.equal((await edit('test-administrator', 2, 'Stale HTTP write')).status, 409);
      assert.equal((await edit('test-administrator', 3, '  ')).status, 400);
    } finally {
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
      await pool.end();
    }
  });
  await t.test('Supabase-style PostgREST verifies JWTs, paginates, and enforces the same policies', async (t) => {
    const secret = randomBytes(32).toString('hex');
    const password = randomBytes(24).toString('hex');
    await db.query(`CREATE ROLE spike_authenticator NOINHERIT LOGIN PASSWORD '${password}';
      GRANT anon, authenticated TO spike_authenticator`);
    await db.query(await readFile(new URL('../supabase/attach.sql', import.meta.url), 'utf8'));
    const { stdout } = await exec('docker', [
      'run', '--rm', '-d', '--network', `container:${process.env.BOOKALOG_TEST_PG_CONTAINER}`,
      '-e', `PGRST_DB_URI=postgresql://spike_authenticator:${password}@127.0.0.1:5432/postgres`,
      '-e', 'PGRST_DB_ANON_ROLE=anon', '-e', `PGRST_JWT_SECRET=${secret}`, '-e', 'PGRST_DB_MAX_ROWS=1000',
      'postgrest/postgrest:v13.0.7',
    ]);
    const container = stdout.trim();
    t.after(() => exec('docker', ['rm', '-f', container]));
    const url = `http://${process.env.BOOKALOG_TEST_REST_ADDRESS}`;
    let ready = false;
    for (let attempt = 0; attempt < 60; attempt++) {
      try {
        const response = await fetch(url);
        ready = response.status < 500;
      } catch {
        // The freshly started container has not bound its socket yet.
      }
      if (ready) break;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    assert.ok(ready, 'PostgREST did not become ready.');
    const token = (sub) => {
      const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
      const payload = Buffer.from(JSON.stringify({ sub, role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 600 })).toString('base64url');
      const signature = createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
      return `${header}.${payload}.${signature}`;
    };
    const authorization = `Bearer ${token('test-viewer')}`;
    assert.equal((await fetch(`${url}/editions`, { headers: { authorization: 'Bearer invalid' } })).status, 401);
    const rows = [];
    for (let offset = 0; offset < 5000; offset += 1000) {
      const response = await fetch(`${url}/editions?select=record&order=id`, {
        headers: { authorization, Range: `${offset}-${offset + 999}` },
      });
      assert.equal(response.ok, true);
      rows.push(...await response.json());
    }
    assert.equal(rows.length, 5000);
    assert.equal(new Set(rows.map((row) => row.record.id)).size, 5000);
    const unapproved = await fetch(`${url}/editions`, { headers: { authorization: `Bearer ${token('unapproved')}` } });
    assert.deepEqual(await unapproved.json(), []);
    const edit = (sub, revision) => fetch(`${url}/rpc/update_edition_title`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token(sub)}`, 'content-type': 'application/json' },
      body: JSON.stringify({ edition_id: editions[0].id, expected_revision: revision, new_title: 'PostgREST title' }),
    });
    assert.equal((await edit('test-viewer', 3)).status, 403);
    assert.equal((await edit('test-administrator', 3)).status, 200);
    assert.equal((await edit('test-administrator', 3)).status, 409);
    if (process.env.BOOKALOG_RUN_NATIVE_MATRIX === '1') {
      await runClientMatrix({ t, db, connectionString, postgrestUrl: url, token });
    }
  });
});
