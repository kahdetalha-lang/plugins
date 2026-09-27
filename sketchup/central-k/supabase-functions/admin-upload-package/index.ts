import { createClient } from "npm:@supabase/supabase-js@2.55.0";

// Upload administrativo dos pacotes .rbz (K.Light, K.Cenas) e da vitrine da Central K pro
// bucket publico "packages". Protegido por um token simples (nao o service role), guardado em
// ck_config. Uso manual pelo Publicador da Central K, nunca chamado pelo plugin do comprador.
//
// Corpo aceito (token sempre obrigatorio):
//   { token, path, content_base64 }   -> envia um arquivo
//   { token, config: { chave: valor } } -> grava versoes da Central/vitrine no ck_config
//                                          (so as chaves da lista abaixo)
const CONFIG_KEYS = new Set([
  "central_k_version", "central_k_download_url", "central_k_sha256",
  "central_k_ui_version", "central_k_ui_manifest_url", "central_k_ui_manifest_sha256",
]);

const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { return reply({ error: "invalid_json" }, 400); }

  const { data: tokenConfig } = await admin.from("ck_config").select("value").eq("key", "admin_upload_token").maybeSingle();
  const expectedToken = tokenConfig?.value;
  const receivedToken = String((body as any).token ?? "");
  if (!expectedToken || receivedToken !== expectedToken) {
    return reply({ error: "invalid_token" }, 401);
  }

  const config = (body as any).config;
  if (config !== undefined) {
    if (!config || typeof config !== "object" || Array.isArray(config)) return reply({ error: "invalid_config" }, 400);
    const rows = Object.entries(config as Record<string, unknown>).map(([key, value]) => ({ key, value: String(value ?? "") }));
    if (!rows.length || rows.some((row) => !CONFIG_KEYS.has(row.key) || row.value.length > 500)) {
      return reply({ error: "invalid_config_key" }, 400);
    }
    const now = new Date().toISOString();
    const { error: configError } = await admin.from("ck_config")
      .upsert(rows.map((row) => ({ ...row, updated_at: now })), { onConflict: "key" });
    if (configError) return reply({ error: configError.message }, 500);
    return reply({ ok: true, config: rows.map((row) => row.key) });
  }

  const path = String((body as any).path ?? "").trim();
  const contentBase64 = String((body as any).content_base64 ?? "");
  if (!path || !contentBase64) {
    return reply({ error: "missing_path_or_content" }, 400);
  }

  const bytes = Uint8Array.from(atob(contentBase64), (c) => c.charCodeAt(0));

  const { error: uploadError } = await admin.storage.from("packages").upload(path, bytes, {
    contentType: "application/octet-stream",
    upsert: true,
  });
  if (uploadError) return reply({ error: uploadError.message }, 500);

  const { data: pub } = admin.storage.from("packages").getPublicUrl(path);

  return reply({ ok: true, path, public_url: pub.publicUrl, size: bytes.length });
});
