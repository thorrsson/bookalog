type LeaseConfig = {
  issuer: string;
  publishableKey: string;
  privateKeyPkcs8: string;
};

type LeaseRuntime = {
  fetcher?: typeof fetch;
  now?: () => number;
  log?: (message: string) => void;
};

const encode = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");

export async function createOfflineLeaseHandler(
  config: LeaseConfig,
  runtime: LeaseRuntime = {},
) {
  const issuer = new URL(config.issuer);
  if (issuer.protocol !== "https:" || issuer.origin !== config.issuer ||
      issuer.username || issuer.password || !config.publishableKey) {
    throw new Error("Offline lease issuer must be an HTTPS origin with a publishable key.");
  }
  const signingKey = await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(
      atob(config.privateKeyPkcs8.replaceAll("-", "+").replaceAll("_", "/")),
      (character) => character.charCodeAt(0),
    ),
    { name: "Ed25519" },
    false,
    ["sign"],
  );
  const fetcher = runtime.fetcher ?? fetch;
  const now = runtime.now ?? Date.now;
  const log = runtime.log ?? console.error;
  const respond = (status: number, body: unknown) => Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return respond(405, { error: "Use POST to request offline access." });
    }
    const authorization = request.headers.get("authorization") ?? "";
    if (!/^Bearer [^\s]+$/.test(authorization)) {
      return respond(401, { error: "Sign in before requesting offline access." });
    }
    const headers = {
      authorization,
      apikey: config.publishableKey,
      "Content-Type": "application/json",
    };
    try {
      const identityResponse = await fetcher(`${config.issuer}/auth/v1/user`, {
        headers, redirect: "error", signal: AbortSignal.timeout(10_000),
      });
      if (identityResponse.status === 401 || identityResponse.status === 403) {
        return respond(401, { error: "Sign in again before requesting offline access." });
      }
      if (!identityResponse.ok) throw new Error("identity_provider_unavailable");
      const identity = await identityResponse.json();
      if (typeof identity.id !== "string" ||
          !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(identity.id)) {
        throw new Error("invalid_identity_response");
      }
      const membershipResponse = await fetcher(
        `${config.issuer}/rest/v1/rpc/current_catalog_role`,
        {
          method: "POST", headers, body: "{}",
          redirect: "error", signal: AbortSignal.timeout(10_000),
        },
      );
      if (membershipResponse.status === 401 || membershipResponse.status === 403) {
        return respond(403, { error: "Catalog membership must be verified online." });
      }
      if (!membershipResponse.ok) throw new Error("membership_provider_unavailable");
      const role = await membershipResponse.json();
      if (!["administrator", "editor", "viewer"].includes(role)) {
        return respond(403, { error: "An active catalog membership is required." });
      }
      const issuedAt = Math.floor(now() / 1000);
      const payload = new TextEncoder().encode(JSON.stringify({
        version: 1,
        issuer: config.issuer,
        subject: identity.id,
        role,
        issued_at: issuedAt,
        expires_at: issuedAt + 24 * 60 * 60,
        nonce: crypto.randomUUID(),
      }));
      const signature = new Uint8Array(
        await crypto.subtle.sign("Ed25519", signingKey, payload),
      );
      return respond(200, { lease: `${encode(payload)}.${encode(signature)}` });
    } catch {
      // Do not log request headers, tokens, or provider response bodies.
      log(JSON.stringify({ event: "offline_lease_failed", reason: "provider_or_signing_error" }));
      return respond(502, { error: "Offline access could not be verified. Retry while online." });
    }
  };
}
