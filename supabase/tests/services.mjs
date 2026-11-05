import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomBytes, randomUUID, verify } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import pg from "pg";
import { createOfflineLeaseHandler } from "../functions/offline-lease/handler.ts";

const directory = process.env.BOOKALOG_SERVICE_TEST_DIRECTORY;
const project = process.env.BOOKALOG_SERVICE_TEST_PROJECT;
assert.ok(directory && /^bookalog-test-[a-f0-9]{12}$/.test(project ?? ""),
  "Run this only through script/test-supabase-services.sh.");
const status = JSON.parse(await readFile(path.join(directory, "status.json"), "utf8"));
const api = status.API_URL;
const anonKey = status.ANON_KEY;
const databaseUrl = status.DB_URL;
assert.ok(api && anonKey && databaseUrl,
  `Local status lacks required connection fields; available names: ${Object.keys(status).join(", ")}`);
const origin = new URL(api);
const databaseOrigin = new URL(databaseUrl);
assert.equal(origin.protocol, "https:");
assert.equal(origin.hostname, "127.0.0.1");
assert.equal(databaseOrigin.hostname, "127.0.0.1");
assert.equal(databaseOrigin.pathname, "/postgres");
const container = `supabase_db_${project}`;
const inspected = JSON.parse(docker("inspect", container).toString())[0];
assert.equal(inspected.Name, `/${container}`);
assert.ok(inspected.NetworkSettings.Ports["5432/tcp"].some(
  (binding) => binding.HostIp === "127.0.0.1" && binding.HostPort === databaseOrigin.port,
), "The database URL must belong to this disposable container.");
const database = new pg.Client({ connectionString: databaseUrl });
await database.connect();

async function request(endpoint, { token, method = "GET", json, bytes, type } = {}) {
  const headers = { apikey: anonKey };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (json !== undefined) headers["Content-Type"] = "application/json";
  if (type) headers["Content-Type"] = type;
  return fetch(new URL(endpoint, origin), {
    method, headers, body: json === undefined ? bytes : JSON.stringify(json),
    redirect: "error", signal: AbortSignal.timeout(20000),
  });
}
async function success(endpoint, options) {
  const response = await request(endpoint, options);
  assert.ok(response.ok, `${options?.method ?? "GET"} ${endpoint.split("?")[0]} returned ${response.status}`);
  return response.status === 204 ? null : response.json();
}
async function rpc(name, token, json = {}) {
  return success(`/rest/v1/rpc/${name}`, { method: "POST", token, json });
}
async function rejected(endpoint, options, expected = [401, 403]) {
  const response = await request(endpoint, options);
  assert.ok(!response.ok, `Unauthorized ${endpoint.split("?")[0]} succeeded`);
  const status = response.status === 400
    ? Number((await response.json()).statusCode) : response.status;
  assert.ok(expected.includes(status), `Unexpected rejection status ${status} for ${endpoint.split("?")[0]}`);
}
function docker(...args) {
  const result = spawnSync("docker", args, { encoding: null, maxBuffer: 32 * 1024 * 1024 });
  assert.equal(result.status, 0, `Disposable database command failed: ${result.stderr?.toString()}`);
  return result.stdout;
}
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

try {
  const accounts = {};
  const clientAccounts = {};
  for (const role of ["administrator", "editor", "viewer", "unapproved"]) {
    const credentials = {
      email: `${role}-${randomUUID()}@bookalog.invalid`,
      password: randomBytes(32).toString("base64url"),
    };
    const registered = await success("/auth/v1/signup", { method: "POST", json: credentials });
    const account = await success("/auth/v1/token?grant_type=password", { method: "POST", json: credentials });
    assert.ok(account.access_token && account.refresh_token && account.user?.id, "Real Auth signup must issue a session.");
    assert.equal(account.user.id, registered.user.id);
    accounts[role] = account;
    clientAccounts[role] = credentials;
    if (role === "administrator") {
      await database.query("INSERT INTO public.memberships (user_id, role) VALUES ($1,$2)", [account.user.id, role]);
    } else if (role !== "unapproved") {
      await rpc("add_catalog_member", accounts.administrator.access_token, { p_email: credentials.email, p_role: role });
    }
  }
  const admin = accounts.administrator.access_token;
  const editor = accounts.editor.access_token;
  const viewer = accounts.viewer.access_token;
  const unapproved = accounts.unapproved.access_token;
  assert.equal(await rpc("current_catalog_role", unapproved), null);
  assert.deepEqual(await success("/rest/v1/catalog_editions?select=record", { token: unapproved }), []);
  await rejected("/rest/v1/catalog_editions?select=record");
  assert.equal((await success("/auth/v1/user", { token: editor })).id, accounts.editor.user.id);

  const created = await rpc("create_work_and_edition", editor, {
    p_title: "Synthetic service check", p_format: "paperback", p_language: "en",
    p_isbn13: "9780306406157", p_publication_status: "announced",
    p_release_date: "2030-02", p_description: "Local provider test only.",
  });
  assert.equal(created.revision, 1);
  assert.deepEqual(await success("/rest/v1/catalog_editions?select=record", { token: unapproved }), []);
  assert.equal((await success("/rest/v1/catalog_editions?select=record", { token: viewer }))[0].record.id, created.id);
  await rejected("/rest/v1/rpc/update_edition_title", {
    method: "POST", token: viewer,
    json: { edition_id: created.id, expected_revision: 1, new_title: "Forbidden" },
  });
  const coverKey = `${created.id}/${randomBytes(16).toString("hex")}.png`;
  const cover = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlWQAAAAASUVORK5CYII=", "base64");
  await rejected(`/storage/v1/object/book-covers/${coverKey}`, {
    method: "POST", token: viewer, bytes: cover, type: "image/png",
  });
  await success(`/storage/v1/object/book-covers/${coverKey}`, {
    method: "POST", token: editor, bytes: cover, type: "image/png",
  });
  const saved = await rpc("update_edition_metadata", editor, {
    p_edition_id: created.id, p_expected_revision: 1,
    p_title: created.title, p_format: created.format, p_language: created.language,
    p_isbn13: created.isbn13, p_publication_status: created.publication_status,
    p_release_date: created.release_date, p_description: created.description, p_cover_key: coverKey,
  });
  assert.equal(saved.revision, 2);
  const conflict = await request("/rest/v1/rpc/update_edition_title", {
    method: "POST", token: editor,
    json: { edition_id: created.id, expected_revision: 1, new_title: "Stale" },
  });
  assert.equal(conflict.status, 409);
  const related = await rpc("update_edition_relations", editor, {
    p_edition_id: created.id, p_expected_revision: saved.revision,
    p_credits: [{ name: "Synthetic Author", role: "author" }, { name: "Synthetic Translator", role: "translator" }],
    p_categories: [{ name: "Local test category" }],
  });
  assert.equal(related.contributors.length, 2);
  assert.equal(related.category_refs.length, 1);
  const importRequest = {
    p_request_id: randomUUID(), p_source_name: "synthetic-services.xml",
    p_source_sha256: hash("Synthetic service import, not a publisher file."),
    p_rows: [{
      source_row: 2, edition_id: null, work_id: created.work_id, expected_revision: null,
      metadata: {
        title: "Synthetic additional edition", format: "ebook", language: "en", isbn13: null,
        publication_status: "announced", release_date: "2030-02", description: "Local restore fixture.",
      },
      source_context: {
        profile: "bookalog-onix-core-v1", record_reference: "synthetic-services-001",
        sender: "Synthetic Sender", sent_at: "20300102T030405Z", publisher: "Synthetic Publisher",
      },
    }],
  };
  const imported = await rpc("import_catalog_metadata", editor, importRequest);
  assert.equal(imported.created, 1);
  assert.deepEqual(await rpc("import_catalog_metadata", editor, importRequest), imported);
  await rejected(`/storage/v1/object/public/book-covers/${coverKey}`, {}, [404]);
  await rejected(`/storage/v1/object/sign/book-covers/${coverKey}`, {
    method: "POST", token: unapproved, json: { expiresIn: 60 },
  }, [404]);
  const signed = await success(`/storage/v1/object/sign/book-covers/${coverKey}`, {
    method: "POST", token: viewer, json: { expiresIn: 300 },
  });
  const signedPath = `/storage/v1${signed.signedURL}`;
  const download = await request(signedPath);
  assert.ok(download.ok, "Viewer's signed private-cover URL must work.");
  const downloadedCover = Buffer.from(await download.arrayBuffer());
  assert.equal(hash(downloadedCover), hash(cover));
  console.log("Real Auth, membership isolation, revision conflict and private Storage access passed.");

  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const handler = await createOfflineLeaseHandler({
    issuer: origin.origin, publishableKey: anonKey,
    privateKeyPkcs8: privateKey.export({ type: "pkcs8", format: "der" }).toString("base64"),
  });
  async function lease(token) {
    return handler(new Request(`${origin}/functions/v1/offline-lease`, {
      method: "POST", headers: { Authorization: `Bearer ${token}` },
    }));
  }
  const leaseResponse = await lease(viewer);
  assert.equal(leaseResponse.status, 200);
  assert.equal(leaseResponse.headers.get("Cache-Control"), "no-store");
  const { lease: token } = await leaseResponse.json();
  const [payload, signature] = token.split(".").map((part) => Buffer.from(part, "base64url"));
  assert.ok(verify(null, payload, publicKey, signature));
  const claims = JSON.parse(payload);
  assert.equal(claims.issuer, origin.origin);
  assert.equal(claims.subject, accounts.viewer.user.id);
  assert.equal(claims.role, "viewer");
  assert.equal(claims.expires_at - claims.issued_at, 86400);
  assert.equal((await lease(unapproved)).status, 403);
  assert.equal((await lease("not-a-token")).status, 401);
  const refreshed = await success("/auth/v1/token?grant_type=refresh_token", {
    method: "POST", json: { refresh_token: accounts.editor.refresh_token },
  });
  assert.equal(refreshed.user.id, accounts.editor.user.id);
  assert.equal(await rpc("current_catalog_role", refreshed.access_token), "editor");
  await rpc("update_catalog_member", admin, {
    p_user_id: accounts.viewer.user.id, p_role: "viewer", p_active: false,
  });
  assert.equal((await lease(viewer)).status, 403);
  assert.deepEqual(await success("/rest/v1/catalog_editions?select=record", { token: viewer }), []);
  await rejected(`/storage/v1/object/sign/book-covers/${coverKey}`, {
    method: "POST", token: viewer, json: { expiresIn: 60 },
  }, [404]);
  // Previously issued URLs are bearer capabilities, not live membership checks.
  assert.ok((await request(signedPath)).ok, "Revocation does not invalidate an unexpired signed cover URL.");
  console.log("Lease handler verified actual provider identities; refresh and membership revocation passed.");

  const tables = [
    "audit_events", "catalog_imports", "categories", "contributors", "edition_categories",
    "edition_credits", "editions", "membership_audit_events", "memberships", "works",
  ];
  assert.deepEqual((await database.query(
    "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY tablename",
  )).rows.map((row) => row.tablename), tables);
  async function snapshot() {
    const result = {};
    for (const table of tables) {
      result[table] = (await database.query(
        `SELECT to_jsonb(item) AS record FROM public.${table} item ORDER BY to_jsonb(item)::text`,
      )).rows;
    }
    return result;
  }
  const before = await snapshot();
  for (const rows of Object.values(before)) assert.ok(rows.length, "Every restored table needs a nonempty fixture.");
  const dump = docker("exec", container, "pg_dump", "-U", "postgres", "-d", "postgres",
    "--format=custom", "--data-only", "--schema=public");
  await writeFile(path.join(directory, "catalog.dump"), dump, { mode: 0o600 });
  await writeFile(path.join(directory, "cover.png"), downloadedCover, { mode: 0o600 });
  await success("/storage/v1/object/book-covers", {
    method: "DELETE", token: editor, json: { prefixes: [coverKey] },
  });
  await rejected(`/storage/v1/object/authenticated/book-covers/${coverKey}`, { token: editor }, [404]);
  await database.query(`TRUNCATE public.catalog_imports, public.audit_events,
    public.edition_credits, public.edition_categories, public.editions,
    public.works, public.contributors, public.categories,
    public.membership_audit_events, public.memberships RESTART IDENTITY`);
  assert.equal((await database.query("SELECT count(*)::int AS count FROM public.editions")).rows[0].count, 0);
  const restore = spawnSync("docker", ["exec", "-i", container, "pg_restore",
    "-U", "postgres", "-d", "postgres", "--exit-on-error", "--single-transaction", "--data-only"],
  { input: await readFile(path.join(directory, "catalog.dump")), maxBuffer: 32 * 1024 * 1024 });
  assert.equal(restore.status, 0, `Data restore failed: ${restore.stderr?.toString()}`);
  assert.deepEqual(await snapshot(), before);
  // Restoring database data must not be mistaken for restoring the separate cover bytes.
  await rejected(`/storage/v1/object/authenticated/book-covers/${coverKey}`, { token: editor }, [404]);
  await success(`/storage/v1/object/book-covers/${coverKey}`, {
    method: "POST", token: editor, bytes: await readFile(path.join(directory, "cover.png")), type: "image/png",
  });
  const restoredCover = await request(`/storage/v1/object/authenticated/book-covers/${coverKey}`, { token: editor });
  assert.ok(restoredCover.ok);
  assert.equal(hash(Buffer.from(await restoredCover.arrayBuffer())), hash(cover));
  assert.equal(await rpc("current_catalog_role", viewer), null);
  assert.deepEqual(await rpc("import_catalog_metadata", editor, importRequest), imported);
  const updatedAfterRestore = await rpc("update_edition_title", editor, {
    edition_id: created.id, expected_revision: related.revision, new_title: "Synthetic post-restore edit",
  });
  assert.equal(updatedAfterRestore.revision, related.revision + 1);
  assert.equal((await database.query("SELECT count(*)::int AS count FROM public.audit_events")).rows[0].count,
    before.audit_events.length + 1);
  await success("/auth/v1/logout?scope=global", { method: "POST", token: refreshed.access_token });
  const afterLogout = await request("/auth/v1/token?grant_type=refresh_token", {
    method: "POST", json: { refresh_token: refreshed.refresh_token },
  });
  assert.equal(afterLogout.status, 400);
  assert.equal((await afterLogout.json()).error_code, "refresh_token_not_found");
  await writeFile(path.join(directory, "client-fixture.json"), JSON.stringify({
    accounts: clientAccounts, editionId: created.id, importRequest, importReport: imported,
  }), { mode: 0o600 });
  console.log("Quiescent catalog data restored exactly; separate cover recovery and digest verification passed.");
} finally {
  await database.end();
}
