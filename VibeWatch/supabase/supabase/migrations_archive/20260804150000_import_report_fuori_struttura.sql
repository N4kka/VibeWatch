-- Redesign 2.0, terzo giro — gli episodi FUORI STRUTTURA escono dall'inbox e si dichiarano.
--
-- Il ramo manuale di import-resolve ora marca in modo TERMINALE ('skipped',
-- error='manuale: fuori_struttura_tmdb') gli episodi di una serie confermata a mano i cui
-- numeri dell'export non esistono nella struttura stagioni TMDB (episodio 0, stagioni che
-- TMDB non ha, speciali assenti). Al primo import vero erano 692 righe su 36 serie: restavano
-- "da verificare" per sempre e ogni retry era un giro a vuoto. Non sono più "da verificare" —
-- sono una perdita DICHIARATA (§7.4): fuori dai non riconosciuti, dentro due campi propri.
--
-- Sostituisce per intero la funzione di `20260804100000_import_exclude_unresolved.sql`;
-- tutto il resto è identico.
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
  -- I non riconosciuti raggruppati per titolo (§7.4). Fuori: gli esclusi dall'utente e i
  -- fuori-struttura — entrambi sono decisioni prese, non lavoro rimasto a metà.
  non_riconosciuti as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           count(*)                                       as episodi,
           min(raw->>'tvdb_series_id')                    as tvdb_series_id,
           min(coalesce(error, 'motivo non registrato'))  as motivo
      from eventi
     where status in ('unresolved', 'skipped')
       and coalesce(error, '') is distinct from 'escluso: utente'
       and coalesce(error, '') is distinct from 'manuale: fuori_struttura_tmdb'
     group by 1
  ),
  fuori_struttura as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           count(*)                                        as episodi
      from eventi
     where error = 'manuale: fuori_struttura_tmdb'
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
  preferiti as (
    select * from righe where raw->>'row_kind' = 'favorite'
  ),
  film as (
    select * from righe where raw->>'row_kind' = 'movie'
  ),
  film_non_risolti as (
    select coalesce(raw->>'title', '(senza titolo)') as titolo,
           raw->>'movie_kind'                        as tipo,
           min(raw->>'tvtime_movie_uuid')            as tvtime_movie_uuid,
           min(coalesce(error, 'motivo non registrato')) as motivo
      from film
     where (status = 'unresolved'
        or (status = 'skipped' and error is distinct from 'film: gia_in_lista'))
       and coalesce(error, '') is distinct from 'escluso: utente'
     group by 1, 2
  ),
  stati as (
    select * from righe where raw->>'row_kind' = 'status'
  ),
  stati_non_risolti as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           raw->>'user_status'                             as stato,
           min(raw->>'tvdb_series_id')                     as tvdb_series_id,
           min(coalesce(error, 'motivo non registrato'))   as motivo
      from stati
     where (status = 'unresolved'
        or (status = 'skipped' and error is distinct from 'stati: stato_gia_in_app'))
       and coalesce(error, '') is distinct from 'escluso: utente'
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
    'film_supportati',   true,
    'film_importati',
        (select count(*) from film where raw->>'movie_kind' = 'seen' and status = 'written'),
    'film_watchlist_importati',
        (select count(*) from film where raw->>'movie_kind' = 'watchlist' and status = 'written'),
    'film_gia_in_app',
        (select count(*) from film
          where status = 'skipped' and error = 'film: gia_in_lista'),
    'film_non_risolti',
        (select count(*) from film_non_risolti),
    'film_non_risolti_elenco',
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'titolo', titolo, 'tipo', tipo, 'motivo', motivo,
                  'tvtime_movie_uuid', tvtime_movie_uuid)
                 order by titolo), '[]'::jsonb)
           from film_non_risolti),

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

    -- I numeri dell'export che la serie confermata non può ospitare: perdita dichiarata,
    -- col suo elenco — non un buco muto e non una card eterna nell'inbox.
    'episodi_fuori_struttura',
        (select coalesce(sum(episodi), 0) from fuori_struttura),
    'fuori_struttura_elenco',
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'titolo', titolo, 'episodi', episodi)
                 order by episodi desc, titolo), '[]'::jsonb)
           from fuori_struttura),

    'voti_stelle',        coalesce((select n from voti where tipo = 'star'), 0),
    'voti_reaction',      coalesce((select n from voti where tipo = 'reaction'), 0),
    'voti_indecodificabili',
                          coalesce((select n from voti where tipo = 'undecodable'), 0),

    'voti_importati',
        (select not exists (
           select 1 from stelle
            where not (status = 'written'
                       or error in ('voti: voto_gia_in_app', 'voti: non_risolto',
                                    'voti: numerazione_mancante', 'voti: voto_fuori_scala',
                                    'voti: senza_episodio')))),
    'voti_stelle_importati',
        (select count(*) from stelle where status = 'written'),
    'voti_stelle_gia_in_app',
        (select count(*) from stelle where error = 'voti: voto_gia_in_app'),
    'voti_stelle_non_risolti',
        (select count(*) from stelle
          where error in ('voti: non_risolto', 'voti: numerazione_mancante',
                          'voti: voto_fuori_scala', 'voti: senza_episodio')),

    'favorites_supportati',   true,
    'favorites_importati',
        (select count(*) from preferiti where status = 'written'),
    'favorites_slot_pieni',
        (select count(*) from preferiti
          where status = 'skipped' and error = 'favorites: slot_pieni'),
    'favorites_gia_in_app',
        (select count(*) from preferiti
          where status = 'skipped' and error = 'favorites: gia_favorito'),
    'favorites_non_risolti',
        (select count(*) from preferiti
          where status = 'unresolved'
             or (status = 'skipped' and error = 'favorites: non_risolto')),
    'favorite_film_non_supportati',
        (select coalesce((totals->>'favorite_movies_unsupported')::int, 0) from job),

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
  'SPEC v3 §7.4 + redesign 2.0: report di fine import. Esclusi dall''utente e fuori-struttura '
  'TMDB stanno fuori dai non riconosciuti e dentro i loro campi dichiarativi. '
  'security invoker: decide la RLS.';

revoke all on function public.import_report(uuid) from public, anon;
grant execute on function public.import_report(uuid) to authenticated;
