import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import pg from 'pg';
import { createGateway } from './gateway.mjs';

if (!process.env.GOOGLE_CLOUD_PROJECT || !process.env.DATABASE_URL) {
  throw new Error('GOOGLE_CLOUD_PROJECT and DATABASE_URL are required. No test authentication fallback is available.');
}
initializeApp({ credential: applicationDefault(), projectId: process.env.GOOGLE_CLOUD_PROJECT });
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
const server = createGateway({
  pool,
  verifyToken: (token) => getAuth().verifyIdToken(token, true),
});
const port = Number(process.env.PORT ?? 8080);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be a valid TCP port.');
server.listen(port, process.env.HOST ?? '127.0.0.1', () => {
  console.log(JSON.stringify({ event: 'listening', port }));
});
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    server.close(async () => {
      await pool.end();
    });
  });
}
