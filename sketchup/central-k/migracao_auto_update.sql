-- Migração JÁ APLICADA no Supabase (Central K Pilot) em 07/10/2026, antes da revisão.
-- Só acrescenta colunas/configurações; nada que existe hoje as lê.
alter table public.ck_products
  add column if not exists download_size bigint,
  add column if not exists install_paths text[] not null default '{}',
  add column if not exists min_sketchup_version text,
  add column if not exists platforms text[] not null default '{win,mac}',
  add column if not exists rollout_percent integer not null default 100 check (rollout_percent between 0 and 100),
  add column if not exists update_paused boolean not null default false;
update public.ck_products set install_paths = '{kcenas.rb,kcenas}', download_size = 27167 where slug = 'kcenas';
update public.ck_products set install_paths = '{01_k_light_l.rb,01_k_light_l}', download_size = 250599 where slug = 'klight';
update public.ck_products set install_paths = '{revest_planner.rb,revest_planner}', download_size = 3843688 where slug = 'revest';
insert into public.ck_config (key, value) values
  ('auto_update_enabled', 'true'),
  ('auto_update_pilot_emails', 'kahdetalha@hotmail.com,kahdetalha@gmail.com')
on conflict (key) do nothing;

-- Para DESFAZER (se você não aprovar):
-- alter table public.ck_products drop column download_size, drop column install_paths, drop column min_sketchup_version,
--   drop column platforms, drop column rollout_percent, drop column update_paused;
-- delete from public.ck_config where key in ('auto_update_enabled','auto_update_pilot_emails');
