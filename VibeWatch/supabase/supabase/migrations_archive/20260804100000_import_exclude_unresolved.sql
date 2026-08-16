-- Redesign 2.0 dell'import — l'inbox "Titoli da verificare" diventa gestibile: l'utente può
-- ESCLUDERE un titolo non riconosciuto (la card sparisce e non torna), e il report smette di
-- contarlo tra i non risolti. L'esclusione è una decisione dell'utente, non una perdita: per
-- questo le righe diventano `skipped` con un motivo suo ('escluso: utente'), distinto da ogni
-- motivo di pipeline.
--
-- Due maniglie diverse perché l'export ne offre due: le SERIE si escludono per
-- `tvdb_series_id` (la stessa maniglia della risoluzione a mano); i FILM non hanno id esterni
-- e si escludono per `tvtime_movie_uuid`. Le rare righe serie SENZA id — quelle su cui il
-- pulsante "Risolvi" non esiste — si escludono per titolo, altrimenti resterebbero
-- nell'inbox per sempre senza alcuna azione possibile.

create or replace function public.import_exclude_unresolved(
  p_job_id uuid,
  p_tvdb_series_ids text[] default null,
  p_movie_uuids text[] default null,
  p_series_titles text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_serie integer := 0;
  v_titoli integer := 0;
  v_film integer := 0;
begin
  -- Solo il proprietario (security definer: il controllo va fatto qui, la RLS non ci copre),
  -- e solo su un job concluso: escludere righe di un job in corsa significherebbe scrivere
  -- sotto i piedi delle fasi — lo stesso vincolo di import-manual-resolve.
  if not exists (
    select 1 from public.import_jobs
     where id = p_job_id
       and user_id = auth.uid()
       and phase = 'done'
       and status = 'done'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'job_not_done');
  end if;

  if p_tvdb_series_ids is not null and cardinality(p_tvdb_series_ids) > 0 then
    update public.import_staging
       set status = 'skipped',
           error = 'escluso: utente'
     where job_id = p_job_id
       and status = 'unresolved'
       and raw->>'row_kind' in ('event', 'status', 'favorite')
       and raw->>'tvdb_series_id' = any(p_tvdb_series_ids);
    get diagnostics v_serie = row_count;
  end if;

  -- Le righe serie senza id: la maniglia è il titolo dell'export. Solo dove l'id manca
  -- davvero — con un id presente il titolo sarebbe una maniglia ambigua.
  if p_series_titles is not null and cardinality(p_series_titles) > 0 then
    update public.import_staging
       set status = 'skipped',
           error = 'escluso: utente'
     where job_id = p_job_id
       and status = 'unresolved'
       and raw->>'row_kind' in ('event', 'status', 'favorite')
       and coalesce(raw->>'tvdb_series_id', '') = ''
       and raw->>'series_name' = any(p_series_titles);
    get diagnostics v_titoli = row_count;
  end if;

  -- Per i film "non risolto" nel report è unresolved OPPURE skipped con un motivo che non sia
  -- `gia_in_lista`: l'esclusione copre lo stesso perimetro, senza mai riscrivere se stessa.
  if p_movie_uuids is not null and cardinality(p_movie_uuids) > 0 then
    update public.import_staging
       set status = 'skipped',
           error = 'escluso: utente'
     where job_id = p_job_id
       and raw->>'row_kind' = 'movie'
       and (status = 'unresolved'
            or (status = 'skipped'
                and error is distinct from 'film: gia_in_lista'
                and error is distinct from 'escluso: utente'))
       and raw->>'tvtime_movie_uuid' = any(p_movie_uuids);
    get diagnostics v_film = row_count;
  end if;

  if v_serie + v_titoli + v_film = 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_exclude');
  end if;

  return jsonb_build_object(
    'ok', true,
    'righe_serie', v_serie + v_titoli,
    'righe_film', v_film
  );
end;
$$;

comment on function public.import_exclude_unresolved(uuid, text[], text[], text[]) is
  'Redesign 2.0 import: esclude dall''inbox "Titoli da verificare" i non riconosciuti che '
  'l''utente ha scelto di lasciar perdere (skipped, error=''escluso: utente''). Solo il '
  'proprietario, solo a job concluso.';

revoke all on function public.import_exclude_unresolved(uuid, text[], text[], text[])
  from public, anon;
grant execute on function public.import_exclude_unresolved(uuid, text[], text[], text[])
  to authenticated;

-- ---------------------------------------------------------------------------------------------
-- `import_report`: gli esclusi escono dai "non risolti" — sono una scelta, non una perdita —
-- e i film portano l'uuid TV Time, che è la maniglia dell'esclusione (senza, il client
-- vedrebbe la card ma non avrebbe come escluderla). Sostituisce per intero la funzione di
-- `20260802210000_import_report_movies.sql`; tutto il resto è identico.
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
  -- Gli esclusi dall'utente ('escluso: utente') non sono perdite e stanno fuori.
  non_riconosciuti as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           count(*)                                       as episodi,
           min(raw->>'tvdb_series_id')                    as tvdb_series_id,
           min(coalesce(error, 'motivo non registrato'))  as motivo
      from eventi
     where status in ('unresolved', 'skipped')
       and coalesce(error, '') is distinct from 'escluso: utente'
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
  -- `gia_in_lista` NON e' una perdita e sta fuori; gli esclusi dall'utente idem. L'uuid
  -- TV Time viaggia con la riga: e' la maniglia di `import_exclude_unresolved`.
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
  -- Un `active` lasciato com'era in app NON e' una perdita e sta fuori da questo elenco;
  -- gli esclusi dall'utente idem.
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
  'SPEC v3 §7.4 + redesign 2.0: il report di fine import. I titoli esclusi dall''utente '
  '(''escluso: utente'') non contano tra i non risolti; i film portano tvtime_movie_uuid '
  'come maniglia dell''esclusione. security invoker: decide la RLS.';

revoke all on function public.import_report(uuid) from public, anon;
grant execute on function public.import_report(uuid) to authenticated;
