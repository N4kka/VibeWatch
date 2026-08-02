-- SPEC v3 §7.2 — le tabelle che rendono l'import ripartibile.
--
-- Il vincolo di progetto e' questo: un utente con 20.000 eventi non finisce in una sessione, e
-- l'app puo' essere chiusa a meta'. Senza uno stato persistito, chiudere l'app significa
-- ricominciare da zero — e chi importa da TV Time ha appena perso tutto una volta (§7.4).
--
-- Da cui due scelte:
--   * la fase e il punto di ripresa stanno sul *server*, non nel client, perche' il client e' la
--     cosa che sparisce;
--   * ogni fase dichiara da dove riparte (`checkpoint`), invece di ricalcolarlo indovinando.

create table if not exists public.import_jobs (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  source       text not null default 'tvtime',
  status       text not null default 'running',
  phase        text not null default 'uploaded',
  -- Da dove riprende la fase corrente: `row_index` in parsing, ultimo batch in resolving,
  -- `dedup_key` in writing, id serie in recomputing (§7.2). Sta in jsonb perche' il significato
  -- cambia con la fase, e inventare cinque colonne nullable per lo stesso concetto e' peggio.
  checkpoint   jsonb not null default '{}'::jsonb,
  -- Cio' che finira' nel report di §7.4. Si aggiorna man mano: se il job muore a meta', quel che
  -- e' stato importato resta dichiarato.
  totals       jsonb not null default '{}'::jsonb,
  storage_path text,
  error        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint import_jobs_source_check check (source in ('tvtime')),
  constraint import_jobs_status_check check (status in ('running','paused','done','failed')),
  constraint import_jobs_phase_check  check (phase in
    ('uploaded','parsing','resolving','writing','recomputing','done'))
);

-- La ripresa cerca "il job non finito di questo utente": e' l'unica lettura calda.
create index if not exists idx_import_jobs_user_open
  on public.import_jobs (user_id, created_at desc)
  where status in ('running','paused');

create table if not exists public.import_staging (
  job_id    uuid not null references public.import_jobs(id) on delete cascade,
  row_index integer not null,
  raw       jsonb not null,
  resolved  jsonb,
  status    text not null default 'pending',
  error     text,
  primary key (job_id, row_index),
  constraint import_staging_status_check check (status in
    ('pending','resolved','written','unresolved','skipped'))
);

-- Le due domande che la pipeline fa a ogni giro: "cosa resta da risolvere/scrivere" e, per il
-- report, "cosa non sono riuscito a riconoscere".
create index if not exists idx_import_staging_job_status
  on public.import_staging (job_id, status, row_index);

-- RLS. Il client legge il proprio avanzamento e basta: nessuna policy di scrittura, come sul
-- catalogo. Le fasi le muove il server, e un client che potesse scrivere `phase='done'` potrebbe
-- dichiarare finito un import che ha perso meta' degli episodi.
alter table public.import_jobs    enable row level security;
alter table public.import_staging enable row level security;

drop policy if exists import_jobs_select_own on public.import_jobs;
create policy import_jobs_select_own on public.import_jobs
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists import_staging_select_own on public.import_staging;
create policy import_staging_select_own on public.import_staging
  for select to authenticated
  using (exists (
    select 1 from public.import_jobs j
     where j.id = import_staging.job_id
       and j.user_id = (select auth.uid())
  ));

create or replace function public.touch_import_job()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_import_jobs_touch on public.import_jobs;
create trigger trg_import_jobs_touch
  before update on public.import_jobs
  for each row execute function public.touch_import_job();

revoke all on function public.touch_import_job() from public;
