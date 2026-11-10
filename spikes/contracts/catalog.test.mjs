import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import readXlsxFile from 'read-excel-file/node';
import { parse } from 'csv-parse/sync';
import { inspectIllustrativeOnix } from './onix.mjs';
import { validateCatalog, validateEdition, searchEditions, canReadOffline, OFFLINE_LEASE_MS } from './catalog.mjs';

const fixture = new URL('../fixtures/generated/', import.meta.url);
const { editions, synthetic } = JSON.parse(await readFile(new URL('catalog.json', fixture), 'utf8'));

test('fixture has exactly 5,000 valid editions, 2,500 works, and meaningful edge cases', () => {
  assert.equal(synthetic, true);
  assert.equal(editions.length, 5000);
  assert.equal(new Set(editions.map((row) => row.work_id)).size, 2500);
  assert.equal(validateCatalog(editions), editions);
  assert.ok(editions.some((row) => row.isbn13 === null));
  assert.ok(editions.some((row) => row.cover_key === null));
  assert.deepEqual(new Set(editions.map((row) => row.release_date?.length ?? 0)), new Set([0, 4, 7, 10]));
});

test('validation rejects duplicate ISBNs, invalid dates, unknown fields, and invalid checksums', async () => {
  const duplicate = JSON.parse(await readFile(new URL('duplicate.json', fixture), 'utf8'));
  assert.throws(() => validateCatalog(duplicate), /Duplicate ISBN/);
  for (const release_date of ['2030-02-30', '2030-13', '2030-00-01']) {
    assert.throws(() => validateEdition({ ...editions[0], release_date }), /Invalid publication date/);
  }
  assert.throws(() => validateEdition({ ...editions[0], privileged: true }), /Invalid edition/);
  assert.throws(() => validateEdition({ ...editions[0], isbn13: '9780000000001' }), /checksum/);
  assert.throws(() => validateEdition({ ...editions[0], title: '  ' }), /blank/);
});

test('shared query semantics cover author, category, Unicode, ISBN, and empty queries', () => {
  assert.equal(searchEditions(editions, '').length, 5000);
  assert.ok(searchEditions(editions, 'SYNTHETIC AUTHOR 39').length > 0);
  assert.ok(searchEditions(editions, 'caf\u00e9').length > 0);
  assert.ok(searchEditions(editions, '\u65e5\u672c\u8a9e').length > 0);
  assert.equal(searchEditions(editions, editions[1].isbn13).length, 1);
  assert.equal(searchEditions(editions, 'not a catalog title').length, 0);
});

test('offline policy expires at exactly 24 hours and fails closed on identity/clock errors', () => {
  const verifiedAt = 1_900_000_000_000;
  const base = { verifiedAt, lastSeenAt: verifiedAt, accountMatches: true, revoked: false };
  assert.equal(canReadOffline({ ...base, now: verifiedAt + OFFLINE_LEASE_MS - 1 }), true);
  assert.equal(canReadOffline({ ...base, now: verifiedAt + OFFLINE_LEASE_MS }), false);
  assert.equal(canReadOffline({ ...base, now: verifiedAt + OFFLINE_LEASE_MS + 1 }), false);
  assert.equal(canReadOffline({ ...base, now: verifiedAt - 1 }), false);
  assert.equal(canReadOffline({ ...base, now: verifiedAt, revoked: true }), false);
  assert.equal(canReadOffline({ ...base, now: verifiedAt, accountMatches: false }), false);
  assert.equal(canReadOffline({ ...base, now: NaN }), false);
});

test('CSV fixture preserves quoting, Unicode, and partial dates; malformed CSV fails', async () => {
  const rows = parse(await readFile(new URL('catalog.csv', fixture)), { columns: true });
  assert.equal(rows.length, 12);
  assert.equal(rows[1].title, editions[1].title);
  assert.equal(rows[2].release_date, '2030-02');
  assert.equal(rows[0].isbn13, '');
  const bad = await readFile(new URL('malformed.csv', fixture));
  assert.throws(() => parse(bad), /Quote Not Closed/);
});

test('XLSX fixture is a real workbook with string ISBNs and dates', async () => {
  const sheets = await readXlsxFile(new URL('catalog.xlsx', fixture).pathname);
  assert.equal(sheets.length, 1);
  const rows = sheets[0].data;
  assert.equal(rows.length, 13);
  assert.equal(rows[2][4], editions[1].isbn13);
  assert.equal(typeof rows[2][4], 'string');
  assert.equal(rows[3][6], '2030-02');
  await assert.rejects(readXlsxFile(new URL('malformed.xlsx', fixture).pathname));
});

test('illustrative ONIX parses as text identifiers; malformed and external-entity XML are distinguishable', async () => {
  const xml = await readFile(new URL('illustrative-onix.xml', fixture), 'utf8');
  const document = inspectIllustrativeOnix(xml);
  assert.equal(document.Product.ProductIdentifier.IDValue, editions[1].isbn13);
  const malformed = await readFile(new URL('malformed-onix.xml', fixture), 'utf8');
  assert.throws(() => inspectIllustrativeOnix(malformed), /Malformed XML/);
  const external = await readFile(new URL('external-entity.xml', fixture), 'utf8');
  assert.throws(() => inspectIllustrativeOnix(external), /external entities/);
});
