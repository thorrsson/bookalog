import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import pg from 'pg';
import { createGateway } from '../google-cloud/gateway.mjs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import readXlsx from 'read-excel-file/node';
import { XMLParser } from 'fast-xml-parser';

const exec = promisify(execFile);

export async function runClientMatrix({ t, db, connectionString, postgrestUrl, token }) {
  await db.query("UPDATE memberships SET active=true WHERE user_id='test-editor'");
  const pool = new pg.Pool({ connectionString });
  const output = await mkdtemp(fileURLToPath(new URL('../fixtures/generated/native-matrix-', import.meta.url)));
  const server = createGateway({
    pool,
    verifyToken: async (value) => {
      if (!['test-editor', 'test-viewer', 'unapproved'].includes(value)) throw new Error('Invalid test token');
      return { uid: value };
    },
  });
  try {
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const cases = [
      { provider: 'postgrest', base_url: postgrestUrl,
        editor_token: token('test-editor'), viewer_token: token('test-viewer'), unapproved_token: token('unapproved') },
      { provider: 'gateway', base_url: `http://127.0.0.1:${server.address().port}`,
        editor_token: 'test-editor', viewer_token: 'test-viewer', unapproved_token: 'unapproved' },
    ];
    const env = { ...process.env, BOOKALOG_MATRIX_CASES: JSON.stringify(cases), BOOKALOG_MATRIX_OUTPUT_DIR: output };
    for (const [name, executable, args, directory] of [
      ['Dart', process.env.DART_BIN ?? 'dart', ['run', 'bin/backend_probe.dart'], '../flutter/'],
      ['Rust', 'cargo', ['run', '--quiet', '--example', 'backend_probe'], '../tauri/src-tauri/'],
    ]) {
      await t.test(`${name} client uses both backends with real HTTP, RLS, and optimistic writes`, async () => {
        const before = Number((await db.query('SELECT count(*) FROM audit_events')).rows[0].count);
        const result = await exec(executable, args, {
          cwd: fileURLToPath(new URL(directory, import.meta.url)), env, timeout: 240_000, maxBuffer: 1024 * 1024,
        });
        assert.match(result.stdout, /both backend paths passed/);
        const after = Number((await db.query('SELECT count(*) FROM audit_events')).rows[0].count);
        assert.equal(after - before, 2, 'Exactly one successful edit per provider should be audited.');
        const fixture = JSON.parse(await readFile(new URL('../fixtures/generated/catalog.json', import.meta.url)));
        const sheets = await readXlsx(await readFile(join(output, `${name.toLowerCase()}.xlsx`)));
        const columns = ['id', 'work_id', 'title', 'format', 'isbn13', 'publication_status', 'release_date'];
        assert.deepEqual(sheets[0].data[0], columns);
        assert.equal(sheets[0].data.length, 5001);
        for (const [index, edition] of fixture.editions.entries()) {
          assert.deepEqual(sheets[0].data[index + 1].map((cell) => cell ?? ''),
            columns.map((column) => edition[column] ?? ''), `XLSX row ${index + 1} must preserve text exactly.`);
        }
        const xml = new XMLParser({ parseTagValue: false }).parse(
          await readFile(join(output, `${name.toLowerCase()}.xml`), 'utf8'));
        const products = xml.ONIXMessage.Product;
        assert.equal(products.length, 5000);
        for (const [index, product] of products.entries()) {
          const edition = fixture.editions[index];
          assert.equal(product.RecordReference, edition.id);
          assert.equal(product.ProductIdentifier.IDValue, edition.isbn13 ?? edition.id);
          assert.equal(product.DescriptiveDetail.TitleDetail.TitleElement.TitleText, edition.title);
          assert.equal(product.DescriptiveDetail.ProductForm, edition.format === 'paperback' ? 'BC' : 'DG');
        }
      });
    }
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    await pool.end();
    await rm(output, { recursive: true, force: true });
  }
}
