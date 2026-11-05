import Ajv from 'ajv';
import schema from './edition.schema.json' with { type: 'json' };

const validate = new Ajv({ allErrors: true }).compile(schema);
export const OFFLINE_LEASE_MS = 24 * 60 * 60 * 1000;

export function validateEdition(edition) {
  if (!validate(edition)) {
    throw new Error(`Invalid edition: ${JSON.stringify(validate.errors)}`);
  }
  if (!edition.title.trim()) throw new Error('Title must not be blank.');
  if (edition.isbn13 !== null) {
    const digits = [...edition.isbn13].map(Number);
    const sum = digits.slice(0, 12).reduce((total, digit, index) => total + digit * (index % 2 ? 3 : 1), 0);
    if ((10 - sum % 10) % 10 !== digits[12]) throw new Error('Invalid ISBN checksum.');
  }
  if (edition.release_date !== null) {
    const [year, month = 1, day = 1] = edition.release_date.split('-').map(Number);
    const parsed = new Date(Date.UTC(year, month - 1, day));
    if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month - 1 || parsed.getUTCDate() !== day) {
      throw new Error('Invalid publication date.');
    }
  }
  return edition;
}

export function validateCatalog(editions) {
  const ids = new Set();
  const isbns = new Set();
  for (const edition of editions) {
    validateEdition(edition);
    if (ids.has(edition.id)) throw new Error(`Duplicate edition ID: ${edition.id}`);
    if (edition.isbn13 && isbns.has(edition.isbn13)) throw new Error(`Duplicate ISBN: ${edition.isbn13}`);
    ids.add(edition.id);
    if (edition.isbn13) isbns.add(edition.isbn13);
  }
  return editions;
}

export function searchEditions(editions, query = '') {
  const needle = query.trim().toLocaleLowerCase('en');
  return editions.filter((edition) => [
    edition.title, edition.isbn13 ?? '', ...edition.contributors.map((credit) => credit.name),
    ...edition.categories,
  ].some((value) => value.toLocaleLowerCase('en').includes(needle)));
}

// Pure policy only: callers must verify membership/lease authenticity and protect persisted clocks.
export function canReadOffline({ verifiedAt, now, lastSeenAt, accountMatches, revoked }) {
  return accountMatches === true && revoked === false
    && [verifiedAt, now, lastSeenAt].every(Number.isFinite)
    && lastSeenAt >= verifiedAt && now >= lastSeenAt
    && now < verifiedAt + OFFLINE_LEASE_MS;
}
