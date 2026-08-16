-- I film "visti" contano anche senza watch_event.
--
-- Asimmetria storica: le serie passano da TrackingActions e scrivono watch_events; i film
-- segnati visti dall'app finiscono SOLO in list_items (lista type='seen') — l'unico writer di
-- watch_events per i film è l'import TV Time. Risultato: get_my_stats (che contava i film da
-- watch_events) rispondeva movies_watched = 0 a chiunque avesse aggiunto i film dall'app.
--
-- Da qui in poi i film sono l'UNIONE delle due sorgenti: gli eventi veri vincono (portano i
-- loro secondi, rewatch compresi); i film che vivono solo nella lista contano una volta con il
-- runtime di catalogo che la riga di lista già porta (minuti TMDB, non una stima — §13.7).
-- Un film presente in entrambe le sorgenti non conta due volte.

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
  mv_extra as (
    -- Film segnati visti dall'app: solo list_items. Se un evento vero esiste (import),
    -- vince l'evento e la riga di lista non aggiunge niente.
    select s.tmdb_movie_id, s.secs
    from (
      select li.media_id as tmdb_movie_id,
             max(coalesce(li.runtime, 0)) * 60 as secs
      from public.list_items li
      join public.lists l on l.id = li.list_id
      where l.user_id = (select auth.uid())
        and l.type = 'seen'
        and l.deleted_at is null
        and li.deleted_at is null
        and li.media_type = 'movie'
      group by 1
    ) s
    where not exists (select 1 from mv where mv.tmdb_movie_id = s.tmdb_movie_id)
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
      coalesce((select sum(secs) from tv), 0)
        + coalesce((select sum(secs) from mv), 0)
        + coalesce((select sum(secs) from mv_extra), 0),
    'episodes_watched',
      (select count(distinct (tmdb_show_id, season_number, episode_number)) from tv),
    'shows_watched', (select count(distinct tmdb_show_id) from tv),
    'movies_watched',
      (select count(distinct tmdb_movie_id) from mv)
        + (select count(*) from mv_extra),
    'ratings_given',
      (select count(*) from public.user_ratings
        where user_id = (select auth.uid()) and deleted_at is null),

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
    'shows_senza_genere',
      (select count(*) from per_show ps
        join public.tmdb_shows s on s.tmdb_show_id = ps.tmdb_show_id
        where s.genres is null or array_length(s.genres, 1) is null)
  );
$$;
