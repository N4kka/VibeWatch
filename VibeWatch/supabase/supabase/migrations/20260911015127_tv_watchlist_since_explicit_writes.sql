-- Recorded on prod as its own version right after tv_watchlist_since; restored here verbatim from
-- supabase_migrations.schema_migrations so the local history matches the remote one.
-- 20260911014807_tv_watchlist_since.sql already carries the same function and backfill, so
-- replaying this on a rebuilt database is a no-op.

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
