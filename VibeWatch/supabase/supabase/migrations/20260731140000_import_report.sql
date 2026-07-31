-- SPEC v3 §7.4 — il report di fine import.
--
-- "Un import che dice «fatto!» e ha silenziosamente perso 200 episodi e' peggio di uno che
-- dichiara il problema. Questi utenti hanno appena perso tutto una volta: la fiducia e' la valuta."
--
-- Sta in SQL e non nella Edge Function per due motivi: si collauda con l'harness che gia' esiste
-- (`supabase/tests/run.sh`), e il client puo' leggerlo da solo senza una chiamata di rete in piu'.
--
-- `security invoker`: nessun controllo scritto a mano su chi sta chiedendo. Le policy
-- `import_jobs_select_own` e `import_staging_select_own` decidono, ed e' la stessa scelta con cui
-- si e' chiuso l'IDOR di `import-parse` — un `if` dimenticato e' esattamente com'e' nato.

-- Le serie toccate da un job, per la fase 5. Sta in SQL e non in una query PostgREST per due
-- ragioni concrete: ordinare e filtrare su un campo dentro `resolved` via PostgREST significa
-- confrontare jsonb e sperare che l'ordinamento sia numerico, e soprattutto PostgREST tronca a
-- **1000 righe** — un import da 21.000 eventi ne perderebbe la coda in silenzio, che e' il difetto
-- gia' trovato in `import-resolve`.
create or replace function public.import_touched_shows(
  p_job_id uuid, p_after integer default 0, p_limit integer default 200)
returns setof integer
language sql
stable
security definer
set search_path = public
as $$
  select distinct (s.resolved->>'tmdb_show_id')::integer as tmdb_show_id
    from public.import_staging s
   where s.job_id = p_job_id
     and s.status = 'written'
     and s.resolved ? 'tmdb_show_id'
     and (s.resolved->>'tmdb_show_id')::integer > coalesce(p_after, 0)
   order by 1
   limit greatest(1, coalesce(p_limit, 200));
$$;

comment on function public.import_touched_shows(uuid, integer, integer) is
  'SPEC v3 §7.2 fase 5: le serie toccate da un job, a blocchi. security definer perche'' la chiama '
  'il server con la chiave di servizio, come recompute_tv_show_state.';

-- Servono ENTRAMBI i revoke. Su Supabase una funzione nuova diventa eseguibile per due strade:
-- Postgres concede EXECUTE a PUBLIC di suo, e un ALTER DEFAULT PRIVILEGES di Supabase lo concede
-- in modo ESPLICITO ad `anon` e `authenticated`. Revocare solo a PUBLIC lascia in piedi i due
-- grant espliciti e `proacl` continua a mostrare `anon=X/postgres` — verificato in produzione.
revoke all on function public.import_touched_shows(uuid, integer, integer)
  from public, anon, authenticated;

create or replace function public.import_report(p_job_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with job as (
    select id, user_id, phase, status, totals, created_at, updated_at, error
      from public.import_jobs where id = p_job_id
  ),
  righe as (
    select s.status, s.error, s.raw
      from public.import_staging s
      join job j on j.id = s.job_id
  ),
  eventi as (
    select * from righe where raw->>'row_kind' = 'event'
  ),
  scritti as (
    select * from eventi where status = 'written'
  ),
  -- I non riconosciuti raggruppati per titolo: §7.4 vuole "l'elenco dei titoli", non un numero.
  -- Il titolo viene dall'export perche' e' l'unica cosa che l'utente riconosce: se avessimo il
  -- nome TMDB vorrebbe dire che la serie era risolta.
  non_riconosciuti as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           count(*)                                       as episodi,
           min(raw->>'tvdb_series_id')                    as tvdb_series_id,
           min(coalesce(error, 'motivo non registrato'))  as motivo
      from eventi
     where status in ('unresolved', 'skipped')
     group by 1
  ),
  voti as (
    select raw->>'kind' as tipo, count(*) as n
      from righe where raw->>'row_kind' = 'rating'
     group by 1
  )
  select jsonb_build_object(
    'job_id',        (select id from job),
    'phase',         (select phase from job),
    'status',        (select status from job),
    'error',         (select error from job),
    'durata_secondi',
        (select extract(epoch from updated_at - created_at)::int from job),

    'episodi_importati', (select count(*) from scritti),
    'serie_importate',
        (select count(distinct raw->>'tvdb_series_id') from scritti),
    -- I film dell'export non si importano ancora, e lo si dice invece di riportare uno zero
    -- indistinguibile da "non ne avevi" (§7.1: il parser oggi legge solo gli episodi).
    'film_importati',    0,
    'film_supportati',   false,

    'dal', (select min(raw->>'watched_at') from scritti),
    'al',  (select max(raw->>'watched_at') from scritti),

    'non_riconosciuti_episodi',
        (select coalesce(sum(episodi), 0) from non_riconosciuti),
    'non_riconosciuti_serie',
        (select count(*) from non_riconosciuti),
    'non_riconosciuti_elenco',
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'titolo', titolo, 'episodi', episodi,
                  'tvdb_series_id', tvdb_series_id, 'motivo', motivo)
                 order by episodi desc, titolo), '[]'::jsonb)
           from non_riconosciuti),

    'voti_stelle',        (select coalesce(n, 0) from voti where tipo = 'star'),
    'voti_reaction',      (select coalesce(n, 0) from voti where tipo = 'reaction'),
    'voti_indecodificabili',
                          (select coalesce(n, 0) from voti where tipo = 'undecodable'),
    -- §3.6: `user_ratings` arriva col blocco 9. Finche' non c'e', i voti sono rinviati e va detto.
    'voti_importati',     false,

    'totali_grezzi',      (select totals from job)
  )
  from job;
$$;

comment on function public.import_report(uuid) is
  'SPEC v3 §7.4: il report obbligatorio di fine import. security invoker: la visibilita'' la '
  'decidono le policy di import_jobs/import_staging, non un controllo scritto a mano.';

-- `import_report` resta chiamabile da `authenticated` di proposito: e' security invoker, quindi
-- le policy di import_jobs/import_staging la limitano gia' al proprietario. Ad `anon` non serve.
revoke all on function public.import_report(uuid) from public, anon;
grant execute on function public.import_report(uuid) to authenticated;
