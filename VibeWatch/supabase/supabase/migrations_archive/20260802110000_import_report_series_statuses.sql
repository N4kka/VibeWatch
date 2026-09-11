-- SPEC v3 §7.1/§7.4 — il report impara gli stati per-serie.
--
-- Dal 2026-08-02 la pipeline importa anche lo stato che TV Time aveva gia' calcolato
-- (`for_later`, `archived`, e le serie seguite mai iniziate): righe `row_kind = 'status'` in
-- staging, upsert di `tv_show_state` in fase 4. Il report deve dichiararli con la stessa
-- onesta' degli episodi: quanti applicati, quanti lasciati com'erano in app (un `active` non
-- sovrascrive una scelta fatta dopo l'export), e SOPRATTUTTO quali serie non si sono risolte —
-- una watchlist che perde una serie in silenzio e' lo stesso fallimento muto di §7.4.
--
-- I report dei job passati non hanno questi campi: il client li tratta come assenti, non come
-- zero — `stati_supportati` esiste per distinguere "niente da dichiarare" da "non si faceva".
--
-- Sostituisce per intero la funzione di `20260731140000_import_report.sql`; la parte eventi e
-- voti e' identica.

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
    -- §3.6: `user_ratings` arriva col blocco 9. Finche' non c'e', i voti sono rinviati e va detto.
    'voti_importati',     false,

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
  'SPEC v3 §7.4: il report obbligatorio di fine import, stati per-serie compresi (§7.1). '
  'security invoker: la visibilita'' la decidono le policy di import_jobs/import_staging.';

-- Stessi grant della versione precedente, ripetuti perche' siano veri anche se questa migration
-- venisse applicata su un database dove quella non e' passata.
revoke all on function public.import_report(uuid) from public, anon;
grant execute on function public.import_report(uuid) to authenticated;
