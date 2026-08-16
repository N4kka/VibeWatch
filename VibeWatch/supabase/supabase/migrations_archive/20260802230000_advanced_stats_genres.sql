-- SPEC v3 §9.3/§10 — le stats AVANZATE (Pro): ripartizione per genere e decade, distribuzione
-- dei voti. Erano bloccate dal dato sui generi, che il catalogo non aveva: da qui in poi
-- `tmdb_shows.genres` lo porta (id TMDB, popolati da `catalog-resolve`/`showRow` a ogni
-- refresh; il backfill delle serie già in catalogo è un giro one-shot di /tv/{id}).
--
-- Le ripartizioni sono su base CATALOGO e si pesano in SECONDI VERI (§13.7: mai stime):
-- gli stessi runtime del totale, raggruppati per i generi/decade della serie. Una serie il
-- cui catalogo non ha ancora i generi non sparisce in silenzio: conta in
-- `shows_senza_genere`, e il client può dirlo.
--
-- La distribuzione dei voti viene da `user_ratings` (righe vive): scala 1-10, la stessa
-- delle mezze stelle.
--
-- Il gating Pro sta nella UI come per le altre funzioni Pro (§10): la funzione risponde i
-- dati al proprietario e basta — sono i SUOI dati, non c'è niente da nascondere a lui.

alter table public.tmdb_shows add column if not exists genres integer[];

comment on column public.tmdb_shows.genres is
  'Id genere TMDB (§9.3 stats avanzate). Null = mai popolato: il refresh del catalogo lo riempie.';

create or replace function public.get_my_stats()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with mine as (
    select media_type, tmdb_movie_id, tmdb_show_id, season_number, episode_number,
           runtime_seconds
    from public.watch_events
    where user_id = (select auth.uid()) and deleted_at is null
  ),
  tv as (
    select m.tmdb_show_id, m.season_number, m.episode_number,
           coalesce(m.runtime_seconds, ep.runtime_minutes * 60, 0) as secs
    from mine m
    left join public.tmdb_episodes ep
      on ep.tmdb_show_id = m.tmdb_show_id
     and ep.season_number = m.season_number
     and ep.episode_number = m.episode_number
    where m.media_type = 'tv'
  ),
  mv as (
    select tmdb_movie_id, coalesce(runtime_seconds, 0) as secs
    from mine
    where media_type = 'movie'
  ),
  per_show as (
    select tmdb_show_id, sum(secs) as secs
    from tv group by 1
  ),
  gen as (
    select g.genre_id, count(*) as shows, sum(ps.secs)::bigint as secs
    from per_show ps
    join public.tmdb_shows s on s.tmdb_show_id = ps.tmdb_show_id
    cross join lateral unnest(coalesce(s.genres, '{}')) as g(genre_id)
    group by 1
  ),
  dec as (
    select (extract(year from s.first_air_date)::int / 10) * 10 as decade,
           count(*) as shows, sum(ps.secs)::bigint as secs
    from per_show ps
    join public.tmdb_shows s on s.tmdb_show_id = ps.tmdb_show_id
    where s.first_air_date is not null
    group by 1
  ),
  voti as (
    select rating, count(*) as n
    from public.user_ratings
    where user_id = (select auth.uid()) and deleted_at is null
    group by 1
  )
  select jsonb_build_object(
    'watch_time_seconds',
      coalesce((select sum(secs) from tv), 0) + coalesce((select sum(secs) from mv), 0),
    'episodes_watched',
      (select count(distinct (tmdb_show_id, season_number, episode_number)) from tv),
    'shows_watched', (select count(distinct tmdb_show_id) from tv),
    'movies_watched', (select count(distinct tmdb_movie_id) from mv),
    'ratings_given',
      (select count(*) from public.user_ratings
        where user_id = (select auth.uid()) and deleted_at is null),

    -- §9.3/§10 (Pro), da qui in giù. Ordinamenti fissati QUI: il client mostra, non riordina.
    'per_genere',
      (select coalesce(jsonb_agg(jsonb_build_object(
                'genre_id', genre_id, 'shows', shows, 'seconds', secs)
               order by secs desc, genre_id), '[]'::jsonb) from gen),
    'per_decade',
      (select coalesce(jsonb_agg(jsonb_build_object(
                'decade', decade, 'shows', shows, 'seconds', secs)
               order by decade), '[]'::jsonb) from dec),
    'voti_distribuzione',
      (select coalesce(jsonb_agg(jsonb_build_object('rating', rating, 'count', n)
               order by rating), '[]'::jsonb) from voti),
    -- Le serie viste il cui catalogo non ha (ancora) i generi: dichiarate, non sparite.
    'shows_senza_genere',
      (select count(*) from per_show ps
        join public.tmdb_shows s on s.tmdb_show_id = ps.tmdb_show_id
        where s.genres is null or array_length(s.genres, 1) is null)
  );
$$;

comment on function public.get_my_stats() is
  'SPEC v3 §9.3: le stats del proprietario — totali (base) e ripartizioni genere/decade/voti '
  '(§10 Pro, gating in UI). Runtime reali (§13.7), security invoker: decide la RLS.';

revoke all on function public.get_my_stats() from public, anon;
grant execute on function public.get_my_stats() to authenticated;
