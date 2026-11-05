import assert from "node:assert/strict";
import { mkdtemp, readFile, rmdir, stat, unlink, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createOfflineLeaseHandler } from "./handler.ts";

const issuer = "https://catalog.example.test";
const subject = "00000000-0000-4000-8000-000000000002";
const timestamp = Date.UTC(2030, 0, 1);
const pair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
const config = {
  issuer,
  publishableKey: "test-publishable-key",
  privateKeyPkcs8: Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey))
    .toString("base64"),
};
const request = (authorization = "Bearer disposable-test-token") =>
  new Request(`${issuer}/functions/v1/offline-lease`, {
    method: "POST", headers: { authorization },
    body: JSON.stringify({ role: "administrator", subject: "attacker", expires_at: 9999999999 }),
  });

test("lease is signed for the verified identity and expires after exactly 24 hours", async () => {
  const calls = [];
  const handler = await createOfflineLeaseHandler(config, {
    now: () => timestamp,
    fetcher: async (url, options) => {
      calls.push(url);
      assert.equal(options.headers.authorization, "Bearer disposable-test-token");
      assert.equal(options.headers.apikey, config.publishableKey);
      assert.equal(options.redirect, "error");
      return Response.json(url.endsWith("/user") ? { id: subject } : "viewer");
    },
  });
  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(calls.length, 2);
  const { lease } = await response.json();
  const [payload, signature] = lease.split(".").map((part) => Buffer.from(part, "base64url"));
  const claims = JSON.parse(payload.toString());
  assert.equal(claims.subject, subject);
  assert.equal(claims.role, "viewer");
  assert.equal(claims.issuer, issuer);
  assert.equal(claims.issued_at, timestamp / 1000);
  assert.equal(claims.expires_at - claims.issued_at, 86400);
  assert.equal(await crypto.subtle.verify("Ed25519", pair.publicKey, signature, payload), true);
  payload[0] ^= 1;
  assert.equal(await crypto.subtle.verify("Ed25519", pair.publicKey, signature, payload), false);
  if (process.env.BOOKALOG_LEASE_TEST_VECTOR) {
    await writeFile(process.env.BOOKALOG_LEASE_TEST_VECTOR, JSON.stringify({
      issuer, subject, now: timestamp, lease,
      publicKey: Buffer.from(await crypto.subtle.exportKey("raw", pair.publicKey))
        .toString("base64url"),
    }), { mode: 0o600 });
  }
});

test("missing and rejected credentials cannot receive a lease", async () => {
  let calls = 0;
  const handler = await createOfflineLeaseHandler(config, {
    fetcher: async () => { calls++; return new Response(null, { status: 401 }); },
  });
  assert.equal((await handler(request(""))).status, 401);
  assert.equal(calls, 0);
  assert.equal((await handler(request())).status, 401);
  assert.equal(calls, 1);
  assert.equal((await handler(new Request(issuer))).status, 405);
});

test("unapproved, revoked and unknown roles cannot receive a lease", async () => {
  for (const role of [null, "owner", {}, false]) {
    const handler = await createOfflineLeaseHandler(config, {
      fetcher: async (url) => Response.json(url.endsWith("/user") ? { id: subject } : role),
    });
    assert.equal((await handler(request())).status, 403);
  }
});

test("provider failures are explicit and logs do not contain credentials", async () => {
  const logs = [];
  const handler = await createOfflineLeaseHandler(config, {
    log: (message) => logs.push(message),
    fetcher: async () => { throw new Error("disposable-test-token"); },
  });
  assert.equal((await handler(request())).status, 502);
  assert.equal(logs.length, 1);
  assert.ok(!logs[0].includes("disposable-test-token"));
  await assert.rejects(createOfflineLeaseHandler({ ...config, issuer: "http://example.test" }));
  await assert.rejects(createOfflineLeaseHandler({ ...config, privateKeyPkcs8: "invalid" }));
});

test("operator key generator produces matching, private Ed25519 keys without overwriting", async () => {
    const directory = await mkdtemp(join(tmpdir(), "bookalog-key-test-"));
    const privatePath = join(directory, ".env.offline-lease");
    const publicPath = join(directory, "offline-public-key.txt");
    try {
      const script = new URL("../../../script/offline-lease-key.rb", import.meta.url);
      execFileSync("ruby", [script.pathname, directory], { stdio: "pipe" });
      const privateBytes = Buffer.from(
        (await readFile(privatePath, "utf8")).trim().slice("OFFLINE_LEASE_PRIVATE_KEY=".length),
        "base64",
      );
      const publicBytes = Buffer.from((await readFile(publicPath, "utf8")).trim(), "base64url");
      const privateKey = await crypto.subtle.importKey("pkcs8", privateBytes, "Ed25519", false, ["sign"]);
      const publicKey = await crypto.subtle.importKey("raw", publicBytes, "Ed25519", false, ["verify"]);
      const content = new TextEncoder().encode("disposable key verification");
      const signature = await crypto.subtle.sign("Ed25519", privateKey, content);
      assert.equal(await crypto.subtle.verify("Ed25519", publicKey, signature, content), true);
      assert.equal((await stat(privatePath)).mode & 0o777, 0o600);
      assert.throws(() => execFileSync("ruby", [script.pathname, directory], { stdio: "pipe" }));
    } finally {
      for (const path of [privatePath, publicPath]) {
        try { await unlink(path); } catch (error) { if (error.code !== "ENOENT") throw error; }
      }
      await rmdir(directory);
    }
});
