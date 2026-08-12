-- Social feed M1 — `activities`: la sorgente server che il commento di testa di SocialView
-- aspetta ("un feed di attività degli amici non ha ancora una sorgente server").
--
-- **Perché una tabella materializzata e non una UNION a query-time.** Like e commenti (M2)
-- devono ancorarsi a un'identità stabile, e la card raggruppata ("ha visto 3 episodi di X") con
-- una chiave sintetica su UNION cambierebbe identità man mano che il gruppo cresce — i commenti
-- resterebbero orfani. Qui il raggruppamento si risolve in scrittura: una riga per
-- (utente, group_key), l'upsert fa crescere `episode_count` senza mai cambiare `id`. Non è
-- fan-out: una riga per attività, non per follower — il filtro del grafo è a read-time in
-- `get_activity_feed`.
--
-- **Cosa NON diventa mai attività.** Lo storico importato (source `import_%`), le date inferite
-- (`watched_at_precision = 'inferred'`) e il bulk-mark dell'intera serie (`bulk_show`, che
-- genererebbe card "ha visto 120 episodi": il suo gesto sociale è la card `show_completed`).
-- Lo stesso predicato vale per trigger e backfill: una sola verità sul filtro.
--
-- **Rating e review confluiscono nella stessa riga** (`rated:{media}:{tmdb}`): la review scritta
-- dopo il voto non crea una card nuova ma arricchisce quella esistente — e i commenti (M2)
-- restano ancorati. Il ricalcolo è un unico helper chiamato da entrambi i trigger: legge lo
-- stato vivo di voto e review e decide upsert o lapide, qualunque sia l'ordine degli eventi.
--
-- **Snapshot titolo/poster solo per le serie** (da `tmdb_shows`): un catalogo film server-side
-- non esiste (lezione di 20260802230000) e le card film si arricchiscono client-side, come già
-- fanno le card di `list_items`.

create table if not exists public.activities (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  activity_type text not null check (activity_type in ('watched','rated','list_created','show_completed')),
  group_key     text not null,
  media_type    text check (media_type in ('movie','tv')),
  tmdb_id       integer,
  episode_count integer,
  rating        smallint check (rating between 1 and 10),
  review_id     uuid references public.user_reviews (id) on delete set null,
  list_id       uuid references public.lists (id) on delete set null,
  title         text,
  poster_path   text,
  occurred_at   timestamptz not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,

  unique (user_id, group_key),

  -- Stessa famiglia di `watch_events_shape`: un'attività senza il suo soggetto non è un dato
  -- con cui il feed possa fare qualcosa. Si rifiuta alla nascita, dove il rifiuto è visibile.
  constraint activities_shape check (
    (activity_type in ('watched','rated') and media_type is not null and tmdb_id is not null and list_id is null)
    or (activity_type = 'list_created' and list_id is not null and media_type is null and tmdb_id is null)
    or (activity_type = 'show_completed' and media_type = 'tv' and tmdb_id is not null and list_id is null)
  )
);

comment on table public.activities is
  'Social feed M1: una riga per card del feed, materializzata dai trigger sulle tabelle sorgente. '
  'group_key deterministica per (utente, gesto): l''upsert aggiorna la card senza cambiarne l''id '
  '(like e commenti M2 si ancorano qui). Import, date inferite e bulk_show non entrano mai. '
  'Scrive solo il server (trigger); il client legge via get_activity_feed.';

-- Il feed di un profilo e il fan-in del following passano da qui...
create index if not exists activities_user_time
  on public.activities (user_id, occurred_at desc) where deleted_at is null;
-- ...il feed Community da qui.
create index if not exists activities_global_time
  on public.activities (occurred_at desc) where deleted_at is null;

alter table public.activities enable row level security;

-- Il proprietario vede le proprie righe (serve al futuro "rimuovi dal feed"); tutti gli altri
-- passano da `get_activity_feed`, che applica profili privati, consenso, blocchi e report.
-- Nessun verbo di scrittura al client: scrivono solo i trigger.
drop policy if exists activities_select_own on public.activities;
create policy activities_select_own on public.activities
  for select using ((select auth.uid()) = user_id);

revoke all on public.activities from public;
revoke all on public.activities from anon;
revoke all on public.activities from authenticated;
grant select on public.activities to authenticated;

-- ------------------------------------------------------------------ helper: card "watched"
--
-- Ricalcola una card di visione dal vero (count sulla sorgente), mai per delta: l'upsert e la
-- lapide escono dallo stesso conteggio, quindi insert, soft-delete e re-insert convergono
-- sempre — la stessa filosofia di `recompute_tv_show_state`.
-- Film: un gruppo per (film, rewatch_index). Serie: un gruppo per (serie, giorno UTC).
create or replace function public.activities_refresh_watch(
  p_user uuid, p_media_type text, p_tmdb integer, p_day date, p_rewatch integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key      text;
  v_count    integer;
  v_last     timestamptz;
  v_episodes integer;
  v_title    text;
  v_poster   text;
begin
  if p_media_type = 'movie' then
    v_key := 'watch:movie:' || p_tmdb || ':' || coalesce(p_rewatch, 0);
    select count(*), max(watched_at) into v_count, v_last
      from public.watch_events
     where user_id = p_user and media_type = 'movie' and tmdb_movie_id = p_tmdb
       and coalesce(rewatch_index, 0) = coalesce(p_rewatch, 0)
       and deleted_at is null
       and source not like 'import\_%' escape '\' and source <> 'bulk_show'
       and watched_at_precision <> 'inferred';
    v_episodes := null;
  elsif p_media_type = 'tv' then
    v_key := 'watch:tv:' || p_tmdb || ':' || p_day;
    select count(*), max(watched_at) into v_count, v_last
      from public.watch_events
     where user_id = p_user and media_type = 'tv' and tmdb_show_id = p_tmdb
       and (watched_at at time zone 'utc')::date = p_day
       and deleted_at is null
       and source not like 'import\_%' escape '\' and source <> 'bulk_show'
       and watched_at_precision <> 'inferred';
    v_episodes := v_count;
    select name, poster_path into v_title, v_poster
      from public.tmdb_shows where tmdb_show_id = p_tmdb;
  else
    return;
  end if;

  if coalesce(v_count, 0) = 0 then
    update public.activities set deleted_at = now(), updated_at = now()
     where user_id = p_user and group_key = v_key and deleted_at is null;
    return;
  end if;

  insert into public.activities as a
    (user_id, activity_type, group_key, media_type, tmdb_id, episode_count,
     title, poster_path, occurred_at)
  values
    (p_user, 'watched', v_key, p_media_type, p_tmdb, v_episodes, v_title, v_poster, v_last)
  on conflict (user_id, group_key) do update set
    episode_count = excluded.episode_count,
    title = coalesce(excluded.title, a.title),
    poster_path = coalesce(excluded.poster_path, a.poster_path),
    occurred_at = excluded.occurred_at,
    deleted_at = null,
    updated_at = now();
end $$;

-- -------------------------------------------------------------------- helper: card "rated"
--
-- Un solo helper per i due trigger (voto e review): legge lo stato vivo di ENTRAMBI e decide.
-- Così l'ordine degli eventi non conta — la bonifica della chiave naturale in `apply_mutations`
-- (lapide alla vecchia review, poi insert della nuova) attraversa due trigger e atterra sempre
-- sulla stessa card.
create or replace function public.activities_refresh_rated(
  p_user uuid, p_media_type text, p_tmdb integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key       text := 'rated:' || p_media_type || ':' || p_tmdb;
  v_rating    smallint;
  v_rating_at timestamptz;
  v_review    uuid;
  v_review_at timestamptz;
  v_title     text;
  v_poster    text;
begin
  if p_media_type not in ('movie','tv') then
    return;  -- i voti agli episodi non fanno card: sarebbero rumore, non un gesto sociale
  end if;

  select rating, updated_at into v_rating, v_rating_at
    from public.user_ratings
   where user_id = p_user and media_type = p_media_type and tmdb_id = p_tmdb
     and season_number is null and episode_number is null
     and deleted_at is null;

  select id, updated_at into v_review, v_review_at
    from public.user_reviews
   where user_id = p_user and media_type = p_media_type and tmdb_id = p_tmdb
     and deleted_at is null;

  if v_rating is null and v_review is null then
    update public.activities set deleted_at = now(), updated_at = now()
     where user_id = p_user and group_key = v_key and deleted_at is null;
    return;
  end if;

  if p_media_type = 'tv' then
    select name, poster_path into v_title, v_poster
      from public.tmdb_shows where tmdb_show_id = p_tmdb;
  end if;

  insert into public.activities as a
    (user_id, activity_type, group_key, media_type, tmdb_id, rating, review_id,
     title, poster_path, occurred_at)
  values
    (p_user, 'rated', v_key, p_media_type, p_tmdb, v_rating, v_review, v_title, v_poster,
     greatest(coalesce(v_rating_at, '-infinity'::timestamptz),
              coalesce(v_review_at, '-infinity'::timestamptz)))
  on conflict (user_id, group_key) do update set
    rating = excluded.rating,
    review_id = excluded.review_id,
    title = coalesce(excluded.title, a.title),
    poster_path = coalesce(excluded.poster_path, a.poster_path),
    occurred_at = excluded.occurred_at,
    deleted_at = null,
    updated_at = now();
end $$;

-- ------------------------------------------------------------ helper: card "show_completed"
--
-- La card nasce solo se della serie esiste almeno un watch event vivo non importato: il
-- `completed_at` che il ricalcolo assegna a una serie arrivata intera da TV Time è datato al
-- giorno dell'import, e senza questo cancello un import da 50 serie complete sarebbe un feed
-- di 50 card "ha finito X" tutte insieme. `bulk_show` invece qui PASSA: marcare l'intera serie
-- come vista è esattamente il gesto "l'ho finita" — è la sua card, quella degli episodi no.
create or replace function public.activities_refresh_completed(
  p_user uuid, p_show integer, p_completed_at timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key    text := 'completed:tv:' || p_show;
  v_title  text;
  v_poster text;
begin
  if p_completed_at is null or not exists (
       select 1 from public.watch_events e
        where e.user_id = p_user and e.media_type = 'tv' and e.tmdb_show_id = p_show
          and e.deleted_at is null
          and e.source not like 'import\_%' escape '\'
     ) then
    update public.activities set deleted_at = now(), updated_at = now()
     where user_id = p_user and group_key = v_key and deleted_at is null;
    return;
  end if;

  select name, poster_path into v_title, v_poster
    from public.tmdb_shows where tmdb_show_id = p_show;

  insert into public.activities as a
    (user_id, activity_type, group_key, media_type, tmdb_id, title, poster_path, occurred_at)
  values
    (p_user, 'show_completed', v_key, 'tv', p_show, v_title, v_poster, p_completed_at)
  on conflict (user_id, group_key) do update set
    title = coalesce(excluded.title, a.title),
    poster_path = coalesce(excluded.poster_path, a.poster_path),
    occurred_at = excluded.occurred_at,
    deleted_at = null,
    updated_at = now();
end $$;

-- ------------------------------------------------------------------------------- trigger
--
-- L'early-return sulle righe escluse non è cosmesi: un import scrive migliaia di watch_events
-- e senza il guard ognuno pagherebbe una count. Le righe che non possono MAI produrre una card
-- escono prima di toccare qualunque cosa.
create or replace function public.tg_watch_events_activities()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.source like 'import\_%' escape '\' or new.source = 'bulk_show'
     or new.watched_at_precision = 'inferred' then
    return null;
  end if;

  if new.media_type = 'movie' and new.tmdb_movie_id is not null then
    perform public.activities_refresh_watch(
      new.user_id, 'movie', new.tmdb_movie_id, null, coalesce(new.rewatch_index, 0));
  elsif new.media_type = 'tv' and new.tmdb_show_id is not null then
    perform public.activities_refresh_watch(
      new.user_id, 'tv', new.tmdb_show_id, (new.watched_at at time zone 'utc')::date, null);
    -- Un watched_at che cambia giorno sposta l'evento di gruppo: si ricalcola anche il vecchio.
    if tg_op = 'UPDATE'
       and (old.watched_at at time zone 'utc')::date <> (new.watched_at at time zone 'utc')::date then
      perform public.activities_refresh_watch(
        new.user_id, 'tv', old.tmdb_show_id, (old.watched_at at time zone 'utc')::date, null);
    end if;
  end if;
  return null;
end $$;

drop trigger if exists watch_events_activities on public.watch_events;
create trigger watch_events_activities
  after insert or update on public.watch_events
  for each row execute function public.tg_watch_events_activities();

create or replace function public.tg_user_ratings_activities()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.activities_refresh_rated(new.user_id, new.media_type, new.tmdb_id);
  return null;
end $$;

drop trigger if exists user_ratings_activities on public.user_ratings;
create trigger user_ratings_activities
  after insert or update on public.user_ratings
  for each row execute function public.tg_user_ratings_activities();

create or replace function public.tg_user_reviews_activities()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.activities_refresh_rated(new.user_id, new.media_type, new.tmdb_id);
  return null;
end $$;

drop trigger if exists user_reviews_activities on public.user_reviews;
create trigger user_reviews_activities
  after insert or update on public.user_reviews
  for each row execute function public.tg_user_reviews_activities();

-- La card della lista non bagna mai `occurred_at` sull'update: una lista rinominata non deve
-- risalire il feed. Torna pubblica dopo un periodo privato? La card si rianima dov'era.
create or replace function public.tg_lists_activities()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_public and new.deleted_at is null then
    insert into public.activities as a
      (user_id, activity_type, group_key, list_id, occurred_at)
    values
      (new.user_id, 'list_created', 'list:' || new.id, new.id, now())
    on conflict (user_id, group_key) do update set
      deleted_at = null,
      updated_at = now();
  else
    update public.activities set deleted_at = now(), updated_at = now()
     where user_id = new.user_id and group_key = 'list:' || new.id and deleted_at is null;
  end if;
  return null;
end $$;

drop trigger if exists lists_activities on public.lists;
create trigger lists_activities
  after insert or update on public.lists
  for each row execute function public.tg_lists_activities();

-- `recompute_tv_show_state` riscrive la riga a OGNI episodio marcato: senza il WHEN sul
-- cambiamento reale di `completed_at` questo trigger girerebbe a vuoto a ogni visione.
create or replace function public.tg_tv_show_state_activities()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.activities_refresh_completed(new.user_id, new.tmdb_show_id, new.completed_at);
  return null;
end $$;

drop trigger if exists tv_show_state_activities_ins on public.tv_show_state;
create trigger tv_show_state_activities_ins
  after insert on public.tv_show_state
  for each row
  when (new.completed_at is not null)
  execute function public.tg_tv_show_state_activities();

drop trigger if exists tv_show_state_activities_upd on public.tv_show_state;
create trigger tv_show_state_activities_upd
  after update on public.tv_show_state
  for each row
  when (old.completed_at is distinct from new.completed_at)
  execute function public.tg_tv_show_state_activities();

-- I helper e i trigger non si chiamano dal client: la lezione di `import_touched_shows`,
-- tutti e tre i ruoli e fa fede `proacl`.
revoke all on function public.activities_refresh_watch(uuid, text, integer, date, integer) from public;
revoke all on function public.activities_refresh_watch(uuid, text, integer, date, integer) from anon;
revoke all on function public.activities_refresh_watch(uuid, text, integer, date, integer) from authenticated;
revoke all on function public.activities_refresh_rated(uuid, text, integer) from public;
revoke all on function public.activities_refresh_rated(uuid, text, integer) from anon;
revoke all on function public.activities_refresh_rated(uuid, text, integer) from authenticated;
revoke all on function public.activities_refresh_completed(uuid, integer, timestamptz) from public;
revoke all on function public.activities_refresh_completed(uuid, integer, timestamptz) from anon;
revoke all on function public.activities_refresh_completed(uuid, integer, timestamptz) from authenticated;
revoke all on function public.tg_watch_events_activities() from public;
revoke all on function public.tg_watch_events_activities() from anon;
revoke all on function public.tg_watch_events_activities() from authenticated;
revoke all on function public.tg_user_ratings_activities() from public;
revoke all on function public.tg_user_ratings_activities() from anon;
revoke all on function public.tg_user_ratings_activities() from authenticated;
revoke all on function public.tg_user_reviews_activities() from public;
revoke all on function public.tg_user_reviews_activities() from anon;
revoke all on function public.tg_user_reviews_activities() from authenticated;
revoke all on function public.tg_lists_activities() from public;
revoke all on function public.tg_lists_activities() from anon;
revoke all on function public.tg_lists_activities() from authenticated;
revoke all on function public.tg_tv_show_state_activities() from public;
revoke all on function public.tg_tv_show_state_activities() from anon;
revoke all on function public.tg_tv_show_state_activities() from authenticated;

-- ------------------------------------------------------------------------------ backfill
--
-- Stessi predicati dei trigger — una sola verità sul filtro — e orizzonte 12 mesi: il feed al
-- lancio deve sembrare vivo, non uno scavo archeologico. Lo storico intero resta dov'era, nel
-- diario e nelle stats. ON CONFLICT DO NOTHING: rigiocare la migration non duplica e non
-- calpesta card che i trigger hanno già aggiornato.

-- Film visti (un gruppo per film+rewatch).
insert into public.activities
  (user_id, activity_type, group_key, media_type, tmdb_id, occurred_at)
select e.user_id, 'watched',
       'watch:movie:' || e.tmdb_movie_id || ':' || coalesce(e.rewatch_index, 0),
       'movie', e.tmdb_movie_id, max(e.watched_at)
  from public.watch_events e
 where e.media_type = 'movie' and e.tmdb_movie_id is not null
   and e.deleted_at is null
   and e.source not like 'import\_%' escape '\' and e.source <> 'bulk_show'
   and e.watched_at_precision <> 'inferred'
   and e.watched_at >= now() - interval '12 months'
 group by e.user_id, e.tmdb_movie_id, coalesce(e.rewatch_index, 0)
on conflict (user_id, group_key) do nothing;

-- Episodi visti (un gruppo per serie+giorno UTC), con snapshot titolo/poster dal catalogo.
insert into public.activities
  (user_id, activity_type, group_key, media_type, tmdb_id, episode_count,
   title, poster_path, occurred_at)
select e.user_id, 'watched',
       'watch:tv:' || e.tmdb_show_id || ':' || (e.watched_at at time zone 'utc')::date,
       'tv', e.tmdb_show_id, count(*), max(s.name), max(s.poster_path), max(e.watched_at)
  from public.watch_events e
  left join public.tmdb_shows s on s.tmdb_show_id = e.tmdb_show_id
 where e.media_type = 'tv' and e.tmdb_show_id is not null
   and e.deleted_at is null
   and e.source not like 'import\_%' escape '\' and e.source <> 'bulk_show'
   and e.watched_at_precision <> 'inferred'
   and e.watched_at >= now() - interval '12 months'
 group by e.user_id, e.tmdb_show_id, (e.watched_at at time zone 'utc')::date
on conflict (user_id, group_key) do nothing;

-- Voti (le review non esistono ancora: la tabella nasce vuota in questa stessa release).
insert into public.activities
  (user_id, activity_type, group_key, media_type, tmdb_id, rating,
   title, poster_path, occurred_at)
select r.user_id, 'rated',
       'rated:' || r.media_type || ':' || r.tmdb_id,
       r.media_type, r.tmdb_id, r.rating, s.name, s.poster_path, r.updated_at
  from public.user_ratings r
  left join public.tmdb_shows s
    on r.media_type = 'tv' and s.tmdb_show_id = r.tmdb_id
 where r.media_type in ('movie','tv')
   and r.deleted_at is null
   and r.updated_at >= now() - interval '12 months'
on conflict (user_id, group_key) do nothing;

-- Liste pubbliche vive (occurred_at = creazione: il meglio che lo storico sappia dire).
insert into public.activities
  (user_id, activity_type, group_key, list_id, occurred_at)
select l.user_id, 'list_created', 'list:' || l.id, l.id, coalesce(l.created_at, now())
  from public.lists l
 where l.is_public and l.deleted_at is null
   and coalesce(l.created_at, now()) >= now() - interval '12 months'
on conflict (user_id, group_key) do nothing;

-- Serie completate — con lo stesso cancello anti-import dell'helper: almeno un evento vivo
-- non importato, o la card non nasce.
insert into public.activities
  (user_id, activity_type, group_key, media_type, tmdb_id, title, poster_path, occurred_at)
select t.user_id, 'show_completed', 'completed:tv:' || t.tmdb_show_id,
       'tv', t.tmdb_show_id, s.name, s.poster_path, t.completed_at
  from public.tv_show_state t
  left join public.tmdb_shows s on s.tmdb_show_id = t.tmdb_show_id
 where t.completed_at is not null
   and t.completed_at >= now() - interval '12 months'
   and exists (
     select 1 from public.watch_events e
      where e.user_id = t.user_id and e.media_type = 'tv'
        and e.tmdb_show_id = t.tmdb_show_id
        and e.deleted_at is null
        and e.source not like 'import\_%' escape '\'
   )
on conflict (user_id, group_key) do nothing;
