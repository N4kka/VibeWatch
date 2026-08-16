-- Il prossimo episodio riparte da dove l'utente e' arrivato, non dal primo buco (bug 2.7).
--
-- Com'era: `next` = primo episodio non visto in ordine (stagione, episodio), su TUTTO il catalogo.
-- Chi comincia Pechino Express dalla stagione 3 segna S3E1 e la card gli propone S1E1 — un
-- episodio che non ha nessuna intenzione di vedere. Lo stesso vale per gli storici importati da
-- TV Time, pieni di buchi vecchi: la card resta ferma su un episodio del 2015 mentre l'utente e'
-- alla stagione in corso, e ogni "visto" sembra non fare niente (era il secondo bug segnalato:
-- marcare un episodio da SeasonView non muoveva ne' il Tracking ne' la strip di Scopri, perche'
-- il puntatore restava dov'era).
--
-- Com'e': `next` = primo episodio non visto **dopo** il punto piu' avanzato che l'utente ha
-- segnato. Se ha visto S3E1, il prossimo e' S3E2. Se non ha visto niente, il punto non esiste e
-- si riparte dal primo episodio del catalogo, come prima.
--
-- Conseguenza accettata, ed e' la semantica di TV Time: un buco **dietro** al punto raggiunto non
-- viene piu' riproposto. Chi ha saltato S1E2 e sta guardando la stagione 4 non se lo vede
-- ricomparire come "prossimo"; se lo vuole recuperare, la lista episodi della stagione ce l'ha
-- sempre, con il suo check non spuntato. Il progresso (watched/aired) continua a contare i buchi,
-- quindi la barra resta onesta: 41/52, non "in pari".
--
-- Il resto della funzione e' identico alla 20260730020000: si sostituisce per intero perche'
-- `create or replace` vuole il corpo completo, non una toppa.
create or replace function public.recompute_tv_show_state(p_user_id uuid, p_tmdb_show_id integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := public.user_today(p_user_id);
  v_specials boolean := public.user_counts_specials(p_user_id);
  -- Il punto raggiunto: l'episodio piu' AVANTI che l'utente ha segnato, non l'ultimo in ordine di
  -- tempo. Chi recupera un vecchio episodio dopo essere arrivato alla stagione 4 non torna
  -- indietro alla stagione 1.
  v_last_season  integer;
  v_last_episode integer;
begin
  select e.season_number, e.episode_number
    into v_last_season, v_last_episode
  from public.watch_events e
  where e.user_id = p_user_id
    and e.tmdb_show_id = p_tmdb_show_id
    and e.deleted_at is null
    and (v_specials or not public.is_special_episode(e.season_number))
  order by e.season_number desc, e.episode_number desc
  limit 1;

  with watched as (
    select distinct e.season_number, e.episode_number
    from public.watch_events e
    where e.user_id = p_user_id
      and e.tmdb_show_id = p_tmdb_show_id
      and e.deleted_at is null
      and (v_specials or not public.is_special_episode(e.season_number))
  ),
  event_stats as (
    select min(e.watched_at) as first_watched_at, max(e.watched_at) as last_watched_at
    from public.watch_events e
    where e.user_id = p_user_id
      and e.tmdb_show_id = p_tmdb_show_id
      and e.deleted_at is null
      and (v_specials or not public.is_special_episode(e.season_number))
  ),
  catalog as (
    select c.season_number, c.episode_number, c.air_date
    from public.tmdb_episodes c
    where c.tmdb_show_id = p_tmdb_show_id
      and (v_specials or not public.is_special_episode(c.season_number))
  ),
  unwatched as (
    select c.* from catalog c
    where not exists (
      select 1 from watched w
      where w.season_number = c.season_number and w.episode_number = c.episode_number
    )
    -- Il cuore della correzione. Confronto per riga: `(3, 2) > (3, 1)` e `(4, 1) > (3, 20)`,
    -- che e' esattamente l'ordine in cui si guarda una serie. Con `v_last_season` null (utente
    -- che non ha ancora visto niente) la condizione cade e vale tutto il catalogo, come prima.
      and (v_last_season is null
           or (c.season_number, c.episode_number) > (v_last_season, v_last_episode))
  ),
  next_any as (      -- anche non ancora uscito: alimenta la timeline
    select * from unwatched order by season_number, episode_number limit 1
  ),
  next_aired as (    -- solo gia' uscito: alimenta backlog_since
    select * from unwatched
    where air_date is not null and air_date <= v_today
    order by season_number, episode_number limit 1
  ),
  counts as (
    select
      -- Gli eventi sono la verita' su cosa l'utente ha visto: si contano anche gli episodi che il
      -- catalogo non conosce (numerazioni divergenti, l'oracolo ne documenta 31 casi su 430).
      (select count(*) from watched)::integer as watched_count,
      (select count(*) from catalog where air_date is not null and air_date <= v_today)::integer as aired_count,
      (select count(*) from catalog)::integer as total_count
  )
  insert into public.tv_show_state as s (
    user_id, tmdb_show_id,
    watched_count, aired_count, total_count,
    last_watched_at, first_watched_at,
    next_season, next_episode, next_air_date,
    backlog_since, completed_at, updated_at
  )
  select
    p_user_id, p_tmdb_show_id,
    c.watched_count, c.aired_count, c.total_count,
    es.last_watched_at, es.first_watched_at,
    na.season_number, na.episode_number, na.air_date,
    case
      when nx.season_number is null then null
      else greatest(nx.air_date::timestamp at time zone 'UTC', es.last_watched_at)
    end,
    case
      when c.total_count > 0 and c.watched_count >= c.total_count then now()
      else null
    end,
    now()
  from counts c
  cross join event_stats es
  left join next_any na on true
  left join next_aired nx on true
  on conflict (user_id, tmdb_show_id) do update set
    watched_count    = excluded.watched_count,
    aired_count      = excluded.aired_count,
    total_count      = excluded.total_count,
    last_watched_at  = excluded.last_watched_at,
    first_watched_at = excluded.first_watched_at,
    next_season      = excluded.next_season,
    next_episode     = excluded.next_episode,
    next_air_date    = excluded.next_air_date,
    backlog_since    = excluded.backlog_since,
    -- La data in cui e' stata finita si conserva: rifinirla non e' finirla di nuovo.
    completed_at     = case when excluded.completed_at is null then null
                            else coalesce(s.completed_at, excluded.completed_at) end,
    updated_at       = now();
    -- user_status resta quello dell'utente, di proposito.
end $$;

-- I grant restano quelli della 20260730020000 (`create or replace` conserva l'ACL): la funzione
-- la chiamano i trigger e i job, mai un client. Si ripete comunque, cosi' chi legge solo questo
-- file non deve dedurlo.
revoke execute on function public.recompute_tv_show_state(uuid, integer) from public, anon, authenticated;

-- Backfill mirato.
--
-- Le righe gia' scritte hanno il puntatore vecchio e nessuno le ricalcola finche' l'utente non
-- tocca quella serie: senza questo giro, il bug resta a schermo per tutti quelli che l'hanno
-- segnalato. Non si ricalcola tutto `tv_show_state` (sono centinaia di righe per utente): solo
-- quelle in cui il puntatore e' DIETRO a un episodio gia' visto, che sono esattamente le righe
-- che la nuova regola cambia. L'indice `watch_events_by_episode` copre l'exists.
do $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select s.user_id, s.tmdb_show_id
    from public.tv_show_state s
    where s.next_season is not null
      and s.next_episode is not null
      and exists (
        select 1
        from public.watch_events e
        where e.user_id = s.user_id
          and e.tmdb_show_id = s.tmdb_show_id
          and e.deleted_at is null
          and (e.season_number, e.episode_number) > (s.next_season, s.next_episode)
      )
  loop
    perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
    v_count := v_count + 1;
  end loop;

  raise notice '[next-episode] righe riallineate al punto raggiunto: %', v_count;
end $$;
