-- A stable "added to the watchlist" time for series.
--
-- The lists sorted watchlist series by tv_show_state.updated_at, which recompute_tv_show_state
-- rewrites on every run: marking an episode, or a new one airing, pushed a show added a month
-- ago above films added yesterday. watchlist_since moves only when the show (re)enters the list:
-- on creation, when a dropped/archived show is put back, and when a finished show gets new
-- episodes (it leaves "Visti" and comes back as the latest addition).
--
-- A BEFORE trigger rather than a change to recompute_tv_show_state / apply_mutations: both
-- write through INSERT ... ON CONFLICT DO UPDATE, so the trigger sees every write and neither
-- function has to know the column exists.

alter table public.tv_show_state add column if not exists watchlist_since timestamptz;

-- Best available guess for existing rows. A finished show that already has new episodes counts
-- from when it was finished; everything else from its first episode, or its last write.
update public.tv_show_state
set watchlist_since = case
  when watched_count > 0 and backlog_since is null and next_season is not null
    then coalesce(completed_at, last_watched_at, updated_at)
  else coalesce(first_watched_at, updated_at)
end
where watchlist_since is null;

-- Never-started shows have no episode dates; where a real "added" signal exists (a legacy TV
-- row in the watchlist, or the release alert created on save) it beats the recompute time.
-- Applied on prod right after the migration; kept here so a rebuilt DB gets the same values.
with signal as (
  select s.user_id, s.tmdb_show_id,
    least(
      (select min(li.added_at) from public.list_items li join public.lists l on l.id = li.list_id and l.type = 'watchlist'
        where li.user_id = s.user_id and li.media_type = 'tv' and li.media_id = s.tmdb_show_id),
      (select min(ra.created_at) from public.release_alerts ra
        where ra.user_id = s.user_id and ra.media_type = 'tv' and ra.media_id = s.tmdb_show_id)
    ) as added
  from public.tv_show_state s
  where coalesce(s.watched_count, 0) = 0 and s.user_status in ('active', 'for_later')
)
update public.tv_show_state s
set watchlist_since = signal.added
from signal
where s.user_id = signal.user_id and s.tmdb_show_id = signal.tmdb_show_id
  and signal.added is not null and signal.added < s.watchlist_since;

create or replace function public.tg_tv_show_state_watchlist_since()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if tg_op = 'INSERT' then
    new.watchlist_since := coalesce(new.watchlist_since, now());
  elsif (old.user_status in ('dropped', 'archived') and new.user_status not in ('dropped', 'archived'))
     or (old.user_status = 'active' and old.watched_count > 0 and old.backlog_since is null
         and old.next_season is null and new.next_season is not null) then
    new.watchlist_since := now();
  else
    -- recompute and apply_mutations never set the column, so NEW already carries OLD's value;
    -- only an explicit write (a backfill) changes it.
    new.watchlist_since := coalesce(new.watchlist_since, old.watchlist_since, now());
  end if;
  return new;
end;
$$;

drop trigger if exists tv_show_state_watchlist_since on public.tv_show_state;
create trigger tv_show_state_watchlist_since
  before insert or update on public.tv_show_state
  for each row execute function public.tg_tv_show_state_watchlist_since();

-- tv_show_state uses per-column grants: the new column is readable like the others.
grant select (watchlist_since) on public.tv_show_state to anon, authenticated, service_role;

-- Same view, one column appended at the end.
create or replace view public.v_tv_tracking with (security_invoker = on) as
 select s.user_id,
    s.tmdb_show_id,
    s.user_status,
    s.watched_count,
    s.aired_count,
    s.total_count,
    s.last_watched_at,
    s.next_season,
    s.next_episode,
    s.next_air_date,
    s.backlog_since,
    s.first_watched_at,
    s.completed_at,
    s.updated_at,
    s.synced_at,
    public.tv_tracking_bucket(s.user_status, s.watched_count, s.backlog_since) as bucket,
    s.next_air_date is not null and s.next_air_date <= public.user_today(s.user_id) as is_next_available,
    sh.name as show_name,
    sh.poster_path as show_poster_path,
    sh.status as show_status,
    ne.name as next_episode_name,
    ne.still_path as next_still_path,
    ne.runtime_minutes as next_runtime_minutes,
    s.watchlist_since
   from public.tv_show_state s
     left join public.tmdb_shows sh on sh.tmdb_show_id = s.tmdb_show_id
     left join public.tmdb_episodes ne on ne.tmdb_show_id = s.tmdb_show_id
       and ne.season_number = s.next_season and ne.episode_number = s.next_episode;

-- The shared watchlist sorts its series the same way.
create or replace function public.list_items_for(p_list public.lists)
returns setof public.list_items
language sql
stable
security definer
set search_path to 'public'
as $$
  select li.*
  from public.list_items li
  where p_list.source_list_type is distinct from 'watchlist'
    and li.list_id = p_list.id
    and li.deleted_at is null
  union all
  select li.*
  from public.lists w
  join public.list_items li on li.list_id = w.id and li.deleted_at is null and li.media_type = 'movie'
  where p_list.source_list_type = 'watchlist'
    and w.user_id = p_list.user_id
    and w.type = 'watchlist'
    and w.deleted_at is null
  union all
  select (jsonb_populate_record(null::public.list_items, jsonb_build_object(
    'id', md5(p_list.id::text || ':tv:' || s.tmdb_show_id)::uuid,
    'list_id', p_list.id,
    'user_id', s.user_id,
    'media_id', s.tmdb_show_id,
    'media_type', 'tv',
    'title', sh.name,
    'poster_path', sh.poster_path,
    'added_at', coalesce(s.watchlist_since, s.updated_at),
    'origin_country', sh.origin_country,
    'release_date', sh.first_air_date::text,
    'genres', sh.genres,
    'created_at', coalesce(s.watchlist_since, s.updated_at)
  ))).*
  from public.tv_show_state s
  join public.tmdb_shows sh on sh.tmdb_show_id = s.tmdb_show_id
  where p_list.source_list_type = 'watchlist'
    and s.user_id = p_list.user_id
    and (
      public.tv_tracking_bucket(s.user_status, s.watched_count, s.backlog_since)
        in ('not_started', 'for_later', 'up_next', 'stale')
      or (public.tv_tracking_bucket(s.user_status, s.watched_count, s.backlog_since) = 'up_to_date'
          and s.next_season is not null)
    );
$$;

revoke all on function public.list_items_for(public.lists) from public, anon, authenticated;
