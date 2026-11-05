import { createOfflineLeaseHandler } from "./handler.ts";

const handler = await createOfflineLeaseHandler({
  issuer: Deno.env.get("SUPABASE_URL") ?? "",
  publishableKey: Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
  privateKeyPkcs8: Deno.env.get("OFFLINE_LEASE_PRIVATE_KEY") ?? "",
});

Deno.serve(handler);
