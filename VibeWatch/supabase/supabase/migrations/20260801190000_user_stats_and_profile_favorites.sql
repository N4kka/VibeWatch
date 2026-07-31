-- SPEC v3 §9.3/§13.7 — blocco 9: le stats di base come aggregato server, e i favorites nel
-- profilo pubblico.
--
-- **Perché le stats le calcola il server.** Il pull di `watch_events` ha una finestra di 12 mesi
-- (§5): in cache c'è un anno, e una somma fatta dal client direbbe un numero sbagliato con la
-- faccia di uno giusto. §13.7 pretende runtime reali: qui la somma parte da `runtime_seconds`
-- (lo snapshot al momento della visione) e ripiega sul catalogo (`tmdb_episodes`) quando lo
-- snapshot manca. Un film senza runtime conta 0, non una stima.
--
-- **`get_my_stats` è invoker, senza parametri.** L'identità è `auth.uid()`, mai un parametro
-- (la lezione dell'IDOR di `import-parse`); tutto ciò che legge — i propri eventi, i propri
-- voti, il catalogo pubblico — è già leggibile dal chiamante sotto RLS, quindi definer non
-- serve e sarebbe superficie in più.
--
-- **Cosa conta e cosa no.** Il tempo somma ogni evento vivo, rewatch inclusi: un rewatch è tempo
-- passato davvero. `episodes_watched` conta gli episodi *distinti* (il rewatch non è un episodio
-- in più), speciali inclusi: "visti" non è "progresso" (§1.3 tiene gli speciali fuori dal
-- progresso, non fuori dalla storia). Le stats avanzate (per anno, generi, decadi, distribuzione
-- voti) sono Pro (§10) e NON stanno qui: per i generi manca il dato a monte — `tmdb_shows` non
-- ha una colonna generi e un catalogo film server-side non esiste — quindi arriveranno con il
-- loro pezzo di catalogo, non da una stima.
--
-- **Le stats altrui restano chiuse.** §9.3 descrive il profilo, ma pubblicare il tempo di
-- visione di un altro utente è una scelta di privacy che la spec non chiede: `get_my_stats`
-- risponde solo del chiamante. I **favorites** invece sono la parte pubblica di §9.3 (due righe
-- da 4): li espone `get_public_profile`, che è già `security definer` — la RLS di
-- `user_favorites` è owner-only apposta, la superficie pubblica passa di qui e da nessun'altra
-- parte. Escono solo slot e tmdb_id: titoli e poster sono catalogo pubblico e li risolve il
-- client.

create or replace function public.get_my_stats()
returns jsonb
language sql
stable
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
        where user_id = (select auth.uid()) and deleted_at is null)
  );
$$;

comment on function public.get_my_stats() is
  'SPEC v3 §9.3/§13.7: stats di base del chiamante, da runtime reali (snapshot, ripiego sul '
  'catalogo). Solo il chiamante: le stats altrui non sono pubbliche. Le avanzate sono Pro (§10) '
  'e aspettano il dato sui generi.';

revoke all on function public.get_my_stats() from public;
revoke all on function public.get_my_stats() from anon;
revoke all on function public.get_my_stats() from authenticated;
grant execute on function public.get_my_stats() to authenticated;

-- ------------------------------------------------------------------- get_public_profile v2
--
-- Identica alla versione di 20260801150000 (prosrc verificato con md5 prima di riscrivere:
-- e66ddda1d0cecb602b21f07c0e39834b) piu' la chiave `favorites`. Il resto dei commenti vive
-- nel file 20260801150000 e vale ancora.
create or replace function public.get_public_profile(p_username text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when pp.id is null then jsonb_build_object('found', false)
  else jsonb_build_object(
    'found', true,
    'id', pp.id,
    'username', pp.username,
    'display_name', pp.display_name,
    'avatar_url', pp.avatar_url,
    'bio', pp.bio,
    'created_at', pp.created_at,
    'followers', (select count(*) from public.user_follows f
                   where f.followee_id = pp.id and f.deleted_at is null),
    'following', (select count(*) from public.user_follows f
                   where f.follower_id = pp.id and f.deleted_at is null),
    'is_following', exists (select 1 from public.user_follows f
                             where f.follower_id = (select auth.uid())
                               and f.followee_id = pp.id and f.deleted_at is null),
    'follows_me', exists (select 1 from public.user_follows f
                           where f.follower_id = pp.id
                             and f.followee_id = (select auth.uid()) and f.deleted_at is null),
    -- §9.3: due righe da 4, la parte pubblica del profilo. La RLS di user_favorites e'
    -- owner-only apposta: la superficie pubblica e' QUESTO definer, non un grant. Solo slot e
    -- tmdb_id — titoli e poster sono catalogo pubblico, li risolve il client.
    'favorites', jsonb_build_object(
      'movie', coalesce((select jsonb_agg(jsonb_build_object('slot', f.slot, 'tmdb_id', f.tmdb_id)
                                          order by f.slot)
                           from public.user_favorites f
                          where f.user_id = pp.id and f.media_type = 'movie'
                            and f.deleted_at is null), '[]'::jsonb),
      'tv', coalesce((select jsonb_agg(jsonb_build_object('slot', f.slot, 'tmdb_id', f.tmdb_id)
                                       order by f.slot)
                        from public.user_favorites f
                       where f.user_id = pp.id and f.media_type = 'tv'
                         and f.deleted_at is null), '[]'::jsonb)))
  end
  from (select 1) as one
  left join public.public_profiles pp
    -- text = lower(...) e non citext = citext: con `search_path = public` l'operatore citext
    -- (schema extensions) non si risolve e Postgres ripiega su text=text, sensibile alle
    -- maiuscole. Il CHECK su profiles garantisce lo username minuscolo, quindi abbassare
    -- l'input equivale al confronto citext — e non dipende dal search_path.
    on pp.username::text = lower(btrim(coalesce(p_username, '')))
   and not exists (
     select 1 from public.user_blocks b
      where b.deleted_at is null
        and ((b.user_id = (select auth.uid()) and b.blocked_user_id = pp.id)
          or (b.user_id = pp.id and b.blocked_user_id = (select auth.uid())))
   );
$$;

comment on function public.get_public_profile(text) is
  'SPEC v3 §9.3: profilo pubblico con contatori, relazione col chiamante e favorites (definer: '
  'la RLS di user_favorites e'' owner-only apposta). Bloccato in un verso qualunque = '
  'found:false, indistinguibile da inesistente.';

revoke all on function public.get_public_profile(text) from public;
revoke all on function public.get_public_profile(text) from anon;
revoke all on function public.get_public_profile(text) from authenticated;
grant execute on function public.get_public_profile(text) to authenticated;
