// POST /api/activate
// Body: { license_key, product, machine_id }
//
// Regras:
// - chave não existe            -> 404 { error: "invalid_key" }
// - produto não bate com a chave -> 403 { error: "wrong_product" }
// - status = revoked             -> 403 { error: "revoked" }
// - status = unused              -> ativa nessa máquina, vira "active"
// - status = active + mesma máquina -> ok, apenas confirma (permite reinstalar)
// - status = active + máquina diferente -> 403 { error: "already_activated" }

import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY // NUNCA a anon key aqui
);

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  const { license_key, product, machine_id } = req.body || {};

  if (!license_key || !product || !machine_id) {
    return res.status(400).json({ error: 'missing_fields' });
  }

  const { data: license, error } = await supabase
    .from('licenses')
    .select('*')
    .eq('license_key', license_key.trim().toUpperCase())
    .single();

  if (error || !license) {
    return res.status(404).json({ error: 'invalid_key' });
  }

  if (license.product !== product) {
    return res.status(403).json({ error: 'wrong_product' });
  }

  if (license.status === 'revoked') {
    return res.status(403).json({ error: 'revoked' });
  }

  if (license.status === 'active') {
    if (license.machine_id === machine_id) {
      // Reativação na mesma máquina (reinstalou o plugin, por exemplo)
      await supabase
        .from('licenses')
        .update({ last_validated_at: new Date().toISOString() })
        .eq('id', license.id);

      return res.status(200).json({ ok: true, status: 'active' });
    }

    return res.status(403).json({ error: 'already_activated' });
  }

  // status === 'unused' -> primeira ativação
  const { error: updateError } = await supabase
    .from('licenses')
    .update({
      status: 'active',
      machine_id,
      activated_at: new Date().toISOString(),
      last_validated_at: new Date().toISOString(),
    })
    .eq('id', license.id);

  if (updateError) {
    return res.status(500).json({ error: 'server_error' });
  }

  return res.status(200).json({ ok: true, status: 'active' });
}
