// GET /api/version?product=kcenas
//
// Devolve a versão mais recente cadastrada pra esse produto e a URL
// pública do arquivo atualizado (guardado no Storage do Supabase,
// bucket "releases").

import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

export default async function handler(req, res) {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  const { product } = req.query;

  if (!product) {
    return res.status(400).json({ error: 'missing_product' });
  }

  const { data, error } = await supabase
    .from('plugin_versions')
    .select('*')
    .eq('product', product)
    .single();

  if (error || !data) {
    return res.status(404).json({ error: 'not_found' });
  }

  const fileUrl = `${process.env.SUPABASE_URL}/storage/v1/object/public/releases/${data.storage_path}`;

  return res.status(200).json({
    version: data.version,
    target_path: data.target_path,
    file_url: fileUrl,
  });
}
