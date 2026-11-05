import { createServer } from 'node:http';

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function bodyJson(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 4096) throw new HttpError(413, 'The edit request is too large.');
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HttpError(400, 'The request must contain valid JSON.');
  }
}

export function createGateway({ pool, verifyToken, logError = console.error }) {
  const send = (response, status, value) => {
    response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    response.end(JSON.stringify(value));
  };
  return createServer(async (request, response) => {
    let client;
    try {
      if (request.url === '/health' && request.method === 'GET') {
        await pool.query('SELECT 1');
        send(response, 200, { status: 'ok', scope: 'catalog-comparison' });
        return;
      }
      const bearer = /^Bearer ([^\s]+)$/.exec(request.headers.authorization ?? '');
      if (!bearer) throw new HttpError(401, 'Sign in before accessing the catalog.');
      let identity;
      try {
        identity = await verifyToken(bearer[1]);
      } catch {
        throw new HttpError(401, 'Sign-in could not be verified. Sign in again.');
      }
      if (typeof identity.uid !== 'string' || !identity.uid) {
        throw new HttpError(401, 'The verified identity has no user identifier.');
      }
      client = await pool.connect();
      await client.query('BEGIN');
      await client.query('SET LOCAL ROLE catalog_client');
      await client.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: identity.uid })]);
      const membership = await client.query('SELECT current_catalog_role() AS role');
      if (!membership.rows[0].role) throw new HttpError(403, 'An active catalog membership is required.');

      let result;
      if (request.url === '/membership' && request.method === 'GET') {
        result = { role: membership.rows[0].role };
      } else if (request.url === '/editions' && request.method === 'GET') {
        const rows = await client.query('SELECT record FROM editions ORDER BY id');
        result = { editions: rows.rows.map((row) => row.record) };
      } else {
        const route = /^\/editions\/([0-9a-f-]{36})$/.exec(request.url ?? '');
        if (!route || request.method !== 'PATCH') throw new HttpError(404, 'Operation not found.');
        const edit = await bodyJson(request);
        if (!edit || typeof edit !== 'object' || Array.isArray(edit)
          || Object.keys(edit).some((key) => !['title', 'expected_revision'].includes(key))
          || typeof edit.title !== 'string'
          || !Number.isSafeInteger(edit.expected_revision) || edit.expected_revision < 1) {
          throw new HttpError(400, 'Provide a title and a positive expected_revision.');
        }
        result = (await client.query('SELECT update_edition_title($1, $2, $3) AS edition',
          [route[1], edit.expected_revision, edit.title])).rows[0];
      }
      await client.query('COMMIT');
      send(response, 200, result);
    } catch (error) {
      if (client) {
        try {
          await client.query('ROLLBACK');
        } catch (rollbackError) {
          logError(JSON.stringify({ event: 'rollback_failed', code: rollbackError.code ?? 'unknown' }));
        }
      }
      const errors = {
        '42501': [403, 'Your role cannot edit the catalog.'],
        PT409: [409, 'This edition changed. Reload and compare your draft.'],
        '22023': [400, 'A title of 1-500 characters is required.'],
        '22P02': [400, 'Invalid edition identifier.'],
        P0002: [404, 'Edition not found.'],
      };
      const [status, message] = error instanceof HttpError
        ? [error.status, error.message]
        : errors[error.code] ?? [500, 'The catalog operation failed. Retry or contact the administrator.'];
      if (status >= 500) logError(JSON.stringify({ event: 'request_failed', code: error.code ?? 'unknown' }));
      send(response, status, { error: message });
    } finally {
      client?.release();
    }
  });
}
