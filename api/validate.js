// POST /api/validate
// Body: { license_key, product, machine_id }
//
// Chamado periodicamente pelo plugin (ex: a cada 7 dias) pra confirmar
// que a licença continua válida e vinculada àquela máquina.
// Não ativa nada nova aqui — só confirma ou derruba.

import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
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
    return res.status(404).json({ valid: false, error: 'invalid_key' });
  }

  if (license.product !== product) {
    return res.status(403).json({ valid: false, error: 'wrong_product' });
  }

  if (license.status === 'revoked') {
    return res.status(403).json({ valid: false, error: 'revoked' });
  }

  if (license.status !== 'active' || license.machine_id !== machine_id) {
    return res.status(403).json({ valid: false, error: 'not_activated_here' });
  }

  await supabase
    .from('licenses')
    .update({ last_validated_at: new Date().toISOString() })
    .eq('id', license.id);

  return res.status(200).json({ valid: true });
}
