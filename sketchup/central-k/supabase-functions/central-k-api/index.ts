import { createClient } from "npm:@supabase/supabase-js@2.55.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
});

const clean = (value: unknown, max: number) => String(value ?? "").trim().slice(0, max);
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const KID = "ck-2026-08";
const TOKEN_TTL_SECONDS = 7 * 24 * 60 * 60;

// ---------------------------------------------------------------------
// Retry curto para consultas ao Postgres/PostgREST. Absorve soluços
// passageiros de infraestrutura (ex.: reload de schema cache, upgrade
// de runtime, blip de rede interna) que às vezes fazem uma consulta
// isolada falhar mesmo com credenciais válidas (service_role nunca
// expira — quando falha aqui, é infraestrutura, não autenticação).
// Sem isso, uma única falha transitória em QUALQUER consulta do
// bootstrap derrubava a função inteira com 503, e o cliente só tinha
// ~4s de retry automático antes de mostrar erro persistente ao usuário.
// Delay curto e só 1 retry: não pode atrasar perceptivelmente uma
// resposta que na esmagadora maioria das vezes já vem certa de primeira.
async function withRetry<T>(
  fn: () => PromiseLike<{ data: T; error: unknown }>,
  attempts = 2,
  delayMs = 300,
): Promise<{ data: T; error: unknown }> {
  let last: { data: T; error: unknown } = { data: null as T, error: null };
  for (let i = 0; i < attempts; i++) {
    last = await fn();
    if (!last.error) return last;
    if (i < attempts - 1) await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
  return last;
}

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
const enc = (s: string) => b64url(new TextEncoder().encode(s));

function pemToDer(pem: string): ArrayBuffer {
  const base64 = pem
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.includes("BEGIN") && !line.includes("END"))
    .join("");
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}

let cachedPrivateKey: CryptoKey | null = null;
async function privateKey(): Promise<CryptoKey> {
  if (cachedPrivateKey) return cachedPrivateKey;
  const raw = Deno.env.get("CK_SIGNING_PRIVATE_KEY_PEM");
  if (!raw) throw new Error("signing_key_not_configured");
  const trimmed = raw.trim();
  const pem = trimmed.startsWith("-----BEGIN")
    ? trimmed
    : new TextDecoder().decode(Uint8Array.from(atob(trimmed), (c) => c.charCodeAt(0)));
  cachedPrivateKey = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return cachedPrivateKey;
}

function signErrorCode(error: unknown): string {
  const msg = error instanceof Error ? error.message : String(error);
  if (msg.includes("signing_key_not_configured")) return "key_unavailable";
  return "sign_failed";
}

async function issueToken(userId: string, productSlug: string, deviceHash: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT", kid: KID };
  const payload = {
    version: 1,
    kid: KID,
    user_id: userId,
    product_slug: productSlug,
    device_hash: deviceHash,
    iat: now,
    exp: now + TOKEN_TTL_SECONDS,
  };
  const signingInput = `${enc(JSON.stringify(header))}.${enc(JSON.stringify(payload))}`;
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    await privateKey(),
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

// ---------------------------------------------------------------------
// Atualização automática dos plugins (ação "updates"). Resposta leve: só versões e dados
// necessários, cada item assinado com a mesma chave das licenças. O texto assinado precisa
// ser idêntico ao montado pela Central (Updater.signing_input).
// ---------------------------------------------------------------------
async function signUpdate(fields: string[]): Promise<string> {
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    await privateKey(),
    new TextEncoder().encode(fields.join("\n")),
  );
  return b64url(new Uint8Array(sig));
}

// Grupo da distribuição gradual: mesmo computador + mesma versão = mesmo número (0-99).
async function rolloutBucket(deviceHash: string, slug: string, version: string): Promise<number> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${deviceHash}:${slug}:${version}`)));
  return ((digest[0] << 24 >>> 0) + (digest[1] << 16) + (digest[2] << 8) + digest[3]) % 100;
}

// Chaves de ck_config devolvidas à Central no bootstrap. As três "ui" (vitrine atualizável)
// foram acrescentadas; Centrais antigas simplesmente ignoram os campos novos.
const CENTRAL_K_CONFIG_KEYS = [
  "central_k_version", "central_k_download_url", "central_k_sha256",
  "central_k_ui_version", "central_k_ui_manifest_url", "central_k_ui_manifest_sha256",
];

// Versão da Central informada pelo cliente (a partir da 1.0.2), gravada no computador para
// acompanhar a migração. Nunca atrasa nem derruba a resposta: erro aqui é só registrado.
const VERSION_RE = /^\d+(\.\d+){1,3}$/;
async function recordCentralVersion(admin: any, deviceId: string | undefined, known: string | null | undefined, version: string) {
  if (!deviceId || !VERSION_RE.test(version) || known === version) return;
  try {
    const { error } = await admin.from("ck_devices")
      .update({ central_version: version, central_version_at: new Date().toISOString() })
      .eq("id", deviceId);
    if (error) console.error(JSON.stringify({ event: "central_version_record_failed", message: error.message }));
  } catch (error) {
    console.error(JSON.stringify({ event: "central_version_record_failed", message: String(error) }));
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { return json({ error: "invalid_json" }, 400); }
  const action = clean(body.action, 40);
  const email = clean(body.email, 200).toLowerCase();
  const clientVersion = clean(body.client_version, 20);

  if (!EMAIL_RE.test(email)) return json({ error: "invalid_email" }, 400);

  try {
    // Purchase lookup must not depend on GoTrue/Auth availability. Accounts are
    // synchronized from auth.users by a database trigger and read with service_role.
    const { data: account, error: accountError } = await withRetry(() =>
      admin.from("ck_accounts").select("user_id,created_at,max_devices").eq("email", email).maybeSingle()
    );
    if (accountError) throw new Error("account_lookup_failed");
    const accountFound = !!account;
    // A non-existent UUID keeps all read queries empty without creating junk Auth users.
    const userId = account?.user_id ?? "00000000-0000-0000-0000-000000000000";
    const accountCreatedAt: string | null = account?.created_at ?? null;
    const accountMaxDevices: number = account?.max_devices ?? 2;

    if (action === "bootstrap") {
      const [productsResult, entitlementsResult, legacyResult, devicesResult, activationsResult, newsResult, configResult] = await Promise.all([
        withRetry(() => admin.from("ck_products").select("id,slug,name,current_version,description,icon_url,download_url,download_sha256,checkout_url,grants_all,tutorial_url,changelog,extension_name").eq("active", true).order("name")),
        withRetry(() => admin.from("ck_entitlements").select("product_id,status,expires_at,source,updates_until").eq("user_id", userId)),
        withRetry(() => admin.rpc("ck_lookup_legacy_entitlements", { p_email: email })),
        withRetry(() => admin.from("ck_devices").select("id,device_hash,friendly_name,platform,sketchup_version,first_seen_at,last_seen_at,revoked_at,central_version").eq("user_id", userId).order("first_seen_at")),
        withRetry(() => admin.from("ck_activations").select("product_id,device_id,activated_at,last_validated_at,revoked_at").eq("user_id", userId)),
        withRetry(() => admin.from("ck_news").select("id,category,title,body,cta_label,cta_url,featured,published_at").eq("active", true).order("published_at", { ascending: false }).limit(20)),
        withRetry(() => admin.from("ck_config").select("key,value").in("key", CENTRAL_K_CONFIG_KEYS)),
      ]);
      const error = productsResult.error || entitlementsResult.error || legacyResult.error || devicesResult.error || activationsResult.error || newsResult.error || configResult.error;
      if (error) throw error;

      const now = Date.now();
      const productsById = new Map((productsResult.data ?? []).map((p) => [p.id, p]));
      const existingEntitlements = entitlementsResult.data ?? [];
      const existingProductIds = new Set(existingEntitlements.map((e) => e.product_id));
      const legacyEntitlements = (legacyResult.data ?? []).filter((e) => !existingProductIds.has(e.product_id));
      const mergedEntitlements = [...existingEntitlements, ...legacyEntitlements];
      const activeEntitlements = mergedEntitlements.filter(
        (e) => e.status === "active" && !(e.expires_at && Date.parse(e.expires_at) <= now)
      );
      const hasPurchases = activeEntitlements.length > 0;
      const allAccess = activeEntitlements.some((e) => productsById.get(e.product_id)?.grants_all);
      const entitledProductIds = new Set(activeEntitlements.map((e) => e.product_id));

      const deviceHash = clean(body.device_hash, 128).toLowerCase();
      const activeDevices = (devicesResult.data ?? []).filter((d) => !d.revoked_at);
      const currentDevice = deviceHash ? activeDevices.find((d) => d.device_hash === deviceHash) : undefined;
      const isKnownDevice = !!currentDevice;
      const deviceBlocked = !!deviceHash && !isKnownDevice && activeDevices.length >= accountMaxDevices;

      const cfg = Object.fromEntries((configResult.data ?? []).map((c) => [c.key, c.value]));
      await recordCentralVersion(admin, currentDevice?.id, currentDevice?.central_version, clientVersion);

      const tokens: Record<string, string> = {};
      const tokenErrors: { slug: string; code: string }[] = [];
      if (currentDevice) {
        const activeActivationsByProduct = new Map(
          (activationsResult.data ?? [])
            .filter((a) => a.device_id === currentDevice.id && !a.revoked_at)
            .map((a) => [a.product_id, a]),
        );
        for (const product of productsResult.data ?? []) {
          const entitled = allAccess || entitledProductIds.has(product.id);
          if (entitled && activeActivationsByProduct.has(product.id)) {
            try {
              tokens[product.slug] = await issueToken(userId, product.slug, deviceHash);
            } catch (signError) {
              console.error("issueToken failed for", product.slug, signError);
              tokenErrors.push({ slug: product.slug, code: signErrorCode(signError) });
            }
          }
        }
      }

      return json({
        account: { id: accountFound ? userId : null, email, created_at: accountCreatedAt },
        device_limit: accountMaxDevices,
        has_purchases: hasPurchases,
        all_access: allAccess,
        device_blocked: deviceBlocked,
        products: productsResult.data,
        entitlements: mergedEntitlements,
        devices: devicesResult.data,
        activations: activationsResult.data,
        news: newsResult.data,
        tokens,
        token_errors: tokenErrors,
        current_device_id: currentDevice ? currentDevice.id : null,
        central_k: {
          version: cfg.central_k_version ?? null,
          download_url: cfg.central_k_download_url ?? null,
          sha256: cfg.central_k_sha256 ?? null,
          ui_version: cfg.central_k_ui_version ?? null,
          ui_manifest_url: cfg.central_k_ui_manifest_url ?? null,
          ui_manifest_sha256: cfg.central_k_ui_manifest_sha256 ?? null,
        },
      });
    }

    if (action === "updates") {
      const deviceHash = clean(body.device_hash, 128).toLowerCase();
      if (!/^[a-f0-9]{64}$/.test(deviceHash)) return json({ error: "invalid_device" }, 400);
      const [productsResult, entitlementsResult, legacyResult, configResult] = await Promise.all([
        withRetry(() => admin.from("ck_products").select("id,slug,name,extension_name,current_version,download_url,download_sha256,download_size,install_paths,min_sketchup_version,platforms,rollout_percent,update_paused,grants_all").eq("active", true)),
        withRetry(() => admin.from("ck_entitlements").select("product_id,status,expires_at").eq("user_id", userId)),
        withRetry(() => admin.rpc("ck_lookup_legacy_entitlements", { p_email: email })),
        withRetry(() => admin.from("ck_config").select("key,value").in("key", ["auto_update_enabled", "auto_update_pilot_emails"])),
      ]);
      const error = productsResult.error || entitlementsResult.error || legacyResult.error || configResult.error;
      if (error) throw error;

      const cfg = Object.fromEntries((configResult.data ?? []).map((c) => [c.key, c.value]));
      if (cfg.auto_update_enabled !== "true") return json({ enabled: false, products: [] });
      const pilot = String(cfg.auto_update_pilot_emails ?? "").toLowerCase().split(",").map((e) => e.trim()).includes(email);

      const now = Date.now();
      const products = productsResult.data ?? [];
      const byId = new Map(products.map((p) => [p.id, p]));
      const own = entitlementsResult.data ?? [];
      const ownIds = new Set(own.map((e) => e.product_id));
      const active = [...own, ...(legacyResult.data ?? []).filter((e: any) => !ownIds.has(e.product_id))]
        .filter((e: any) => e.status === "active" && !(e.expires_at && Date.parse(e.expires_at) <= now));
      const allAccess = active.some((e: any) => byId.get(e.product_id)?.grants_all);
      const entitledIds = new Set(active.map((e: any) => e.product_id));

      const items = [];
      for (const p of products) {
        if (p.grants_all || !(allAccess || entitledIds.has(p.id))) continue;
        const version = String(p.current_version ?? "");
        const sha = String(p.download_sha256 ?? "").toUpperCase();
        const installPaths: string[] = p.install_paths ?? [];
        if (!VERSION_RE.test(version) || !/^[A-F0-9]{64}$/.test(sha) || !String(p.download_url ?? "").startsWith("https://") || !installPaths.length) continue;
        const platforms: string[] = p.platforms ?? [];
        const size = Number(p.download_size ?? 0);
        const minSketchup = String(p.min_sketchup_version ?? "");
        const percent = Number(p.rollout_percent ?? 100);
        const included = pilot || percent >= 100 || (percent > 0 && await rolloutBucket(deviceHash, p.slug, version) < percent);
        let signature = "";
        try {
          signature = await signUpdate(["ck-update-v1", p.slug, version, sha, String(size), p.download_url, minSketchup, platforms.join(","), installPaths.join("|")]);
        } catch (signError) {
          console.error("update signing failed for", p.slug, signError);
          continue;
        }
        items.push({
          slug: p.slug, version, url: p.download_url, sha256: sha, size, min_sketchup_version: minSketchup,
          platforms, install_paths: installPaths,
          extension_names: [p.extension_name, p.name].filter((n) => typeof n === "string" && n.trim()),
          paused: !!p.update_paused, rollout_included: included, kid: KID, signature,
        });
      }
      return json({ enabled: true, products: items });
    }

    if (action === "activate") {
      const deviceHash = clean(body.device_hash, 128).toLowerCase();
      const productSlug = clean(body.product_slug, 50).toLowerCase();
      if (!/^[a-f0-9]{64}$/.test(deviceHash)) return json({ error: "invalid_device" }, 400);

      const { data: product, error: productError } = await withRetry(() =>
        admin.from("ck_products").select("id,slug,name,current_version").eq("slug", productSlug).eq("active", true).single()
      );
      if (productError || !product) return json({ error: "product_not_found" }, 404);

      let activationUserId = userId;
      let legacyEntitlements: any[] | null = null;

      if (!accountFound) {
        const legacyLookup = await withRetry(() => admin.rpc("ck_lookup_legacy_entitlements", { p_email: email }));
        if (legacyLookup.error) throw new Error("legacy_lookup_failed");
        legacyEntitlements = legacyLookup.data ?? [];
        const hasLegacyPurchase = legacyEntitlements.some(
          (e: any) => e.product_id === product.id && e.status === "active"
        );
        if (!hasLegacyPurchase) return json({ error: "not_entitled" }, 403);

        const created = await admin.auth.admin.createUser({ email, email_confirm: true });
        if (created.error || !created.data.user) {
          // A concurrent activation may have created the account after our first lookup.
          const retryAccount = await withRetry(() =>
            admin.from("ck_accounts").select("user_id").eq("email", email).maybeSingle()
          );
          if (retryAccount.error || !retryAccount.data?.user_id) {
            throw new Error("user_create_failed");
          }
          activationUserId = retryAccount.data.user_id;
        } else {
          activationUserId = created.data.user.id;
        }
      }

      const { data: activeEnts, error: entitlementError } = await withRetry(() =>
        admin.from("ck_entitlements")
          .select("product_id, status, expires_at, ck_products(grants_all)")
          .eq("user_id", activationUserId).eq("status", "active")
      );
      if (entitlementError) throw entitlementError;

      const now = Date.now();
      let entitled = (activeEnts ?? []).some((e: any) => {
        if (e.expires_at && Date.parse(e.expires_at) <= now) return false;
        return e.product_id === product.id || e.ck_products?.grants_all;
      });

      if (!entitled) {
        if (!legacyEntitlements) {
          const legacyLookup = await withRetry(() => admin.rpc("ck_lookup_legacy_entitlements", { p_email: email }));
          if (legacyLookup.error) throw new Error("legacy_lookup_failed");
          legacyEntitlements = legacyLookup.data ?? [];
        }
        const legacy = legacyEntitlements.find(
          (e: any) => e.product_id === product.id && e.status === "active"
        );
        if (legacy) {
          const imported = await admin.from("ck_entitlements").upsert({
            user_id: activationUserId,
            product_id: product.id,
            status: "active",
            source: "purchase",
            expires_at: legacy.expires_at,
            updates_until: legacy.updates_until,
          }, { onConflict: "user_id,product_id" });
          if (imported.error) throw imported.error;
          entitled = true;
        }
      }

      if (!entitled) return json({ error: "not_entitled" }, 403);

      const { data: device, error: deviceError } = await admin.rpc("ck_register_device", {
        p_user_id: activationUserId,
        p_device_hash: deviceHash,
        p_friendly_name: clean(body.friendly_name, 100) || "Meu computador",
        p_platform: clean(body.platform, 100),
        p_sketchup_version: clean(body.sketchup_version, 40),
      });
      if (deviceError) {
        if (deviceError.message.includes("device_limit_reached")) return json({ error: "device_limit_reached", limit: accountMaxDevices }, 409);
        throw deviceError;
      }

      await recordCentralVersion(admin, device?.id, null, clientVersion);

      const { data: activation, error: activationError } = await admin.from("ck_activations").upsert({
        user_id: activationUserId,
        product_id: product.id,
        device_id: device.id,
        last_validated_at: new Date().toISOString(),
        revoked_at: null,
      }, { onConflict: "user_id,product_id,device_id" }).select("id,activated_at,last_validated_at").single();
      if (activationError) throw activationError;

      let token: string;
      try {
        token = await issueToken(activationUserId, productSlug, deviceHash);
      } catch (signError) {
        console.error("issueToken failed for", productSlug, signError);
        return json({ error: "token_signing_failed" }, 500);
      }

      return json({
        ok: true,
        product,
        device: { id: device.id, friendly_name: device.friendly_name },
        activation,
        token,
      });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const code = [
      "account_lookup_failed",
      "user_lookup_failed",
      "user_create_failed",
    ].includes(message) ? message : "internal_error";
    console.error(JSON.stringify({ event: "central_k_error", action, code, message }));
    return json({ error: code }, 503);
  }
});
