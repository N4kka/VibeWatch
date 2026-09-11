-- SPEC v3 §7.5 — i voti nel report di fine import, ora che la fase 4 li scrive davvero
-- (import-write v5: righe `row_kind='rating'` → `user_ratings` via `apply_mutations`).
--
-- `voti_importati` smette di essere un `false` cablato e diventa STRUTTURALE: è vero quando
-- ogni riga stella è stata processata dalla pipeline nuova (scritta, o saltata con una delle
-- sue ragioni). Un job vecchio — stelle rinviate col messaggio del blocco 9 — resta `false`
-- senza toccare niente: il suo report continua a dire la verità di quando è girato.
--
-- I tre contatori nuovi seguono la grammatica degli stati: importati / lasciati in app
-- (un voto già presente non si sovrascrive, lapidi comprese — non è una perdita) / non
-- risolti (questi sì, e quasi sempre sono episodi già nell'elenco dei non riconosciuti).
--
-- Sostituisce per intero la funzione di `20260802110000_import_report_series_statuses.sql`;
-- eventi e stati sono identici.

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
  ),
  stelle as (
    select * from righe where raw->>'row_kind' = 'rating' and raw->>'kind' = 'star'
  ),
  stati as (
    select * from righe where raw->>'row_kind' = 'status'
  ),
  -- Un `active` lasciato com'era in app NON e' una perdita e sta fuori da questo elenco; tutto
  -- il resto dei non applicati si': e' una serie della watchlist che sparirebbe in silenzio.
  stati_non_risolti as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           raw->>'user_status'                             as stato,
           min(raw->>'tvdb_series_id')                     as tvdb_series_id,
           min(coalesce(error, 'motivo non registrato'))   as motivo
      from stati
     where status = 'unresolved'
        or (status = 'skipped' and error is distinct from 'stati: stato_gia_in_app')
     group by 1, 2
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

    -- Il coalesce va FUORI dalla sottoquery: dentro non viene mai eseguito quando la sottoquery
    -- non trova righe, e il report dichiarava `null` invece di zero. Un report che dice "null
    -- voti" non e' un report onesto, e' un report rotto.
    'voti_stelle',        coalesce((select n from voti where tipo = 'star'), 0),
    'voti_reaction',      coalesce((select n from voti where tipo = 'reaction'), 0),
    'voti_indecodificabili',
                          coalesce((select n from voti where tipo = 'undecodable'), 0),

    -- §7.5: vero quando ogni stella e' passata dalla pipeline nuova (scritta o saltata con una
    -- delle SUE ragioni). Un job vecchio — stelle rinviate al blocco 9 — resta false da solo.
    'voti_importati',
        (select not exists (
           select 1 from stelle
            where not (status = 'written'
                       or error in ('voti: voto_gia_in_app', 'voti: non_risolto',
                                    'voti: numerazione_mancante', 'voti: voto_fuori_scala',
                                    'voti: senza_episodio')))),
    'voti_stelle_importati',
        (select count(*) from stelle where status = 'written'),
    -- Un voto gia' presente in app (lapidi comprese) non si sovrascrive: e' una scelta fatta
    -- dopo l'export, non una perdita. Conta a parte, come gli stati lasciati in app.
    'voti_stelle_gia_in_app',
        (select count(*) from stelle where error = 'voti: voto_gia_in_app'),
    'voti_stelle_non_risolti',
        (select count(*) from stelle
          where error in ('voti: non_risolto', 'voti: numerazione_mancante',
                          'voti: voto_fuori_scala', 'voti: senza_episodio')),

    -- §7.1: gli stati per-serie. `stati_supportati` distingue un job vecchio (campi assenti,
    -- il client non mostra la riga) da un import senza stati da applicare (zeri veri).
    'stati_supportati',   true,
    'stati_serie_importati',
        (select count(*) from stati where status = 'written'),
    'stati_serie_lasciati_in_app',
        (select count(*) from stati
          where status = 'skipped' and error = 'stati: stato_gia_in_app'),
    'stati_serie_non_risolti',
        (select count(*) from stati_non_risolti),
    'stati_non_risolti_elenco',
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'titolo', titolo, 'stato', stato,
                  'tvdb_series_id', tvdb_series_id, 'motivo', motivo)
                 order by titolo), '[]'::jsonb)
           from stati_non_risolti),

    'totali_grezzi',      (select totals from job)
  )
  from job;
$$;

comment on function public.import_report(uuid) is
  'SPEC v3 §7.4: il report obbligatorio di fine import — stati per-serie (§7.1) e voti in '
  'stelle (§7.5) compresi. security invoker: la visibilita'' la decidono le policy di '
  'import_jobs/import_staging.';

-- Stessi grant delle versioni precedenti, ripetuti perche' siano veri anche se questa migration
-- venisse applicata su un database dove quelle non sono passate.
revoke all on function public.import_report(uuid) from public, anon;
grant execute on function public.import_report(uuid) to authenticated;
