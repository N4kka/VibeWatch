-- Saving a title is the subscription. Auto-enrollment for watchlist *and* custom lists.
--
-- **The problem.** Being told when something you saved comes out, or lands on a platform you
-- have, is the job this system exists for — and it reached almost nobody: it required tapping
-- "Notify me" on each title, and across the whole user base that produced 8 subscriptions. The
-- watchlist trigger did create alert rows, but only for the watchlist, and release-radar
-- deliberately ignores them (they were the source of the 2026-07-23 storm that announced
-- decades-old catalogue titles as new releases).
--
-- **What changes.** Every item saved to any list creates an alert; removing it from every list
-- retires it. release-radar can now read those sources because the guard that made the storm
-- possible was never the source column: it is the two-day release window plus
-- `last_notified_at is null`, both already in place. A back-catalogue title has a release date
-- outside the window and is never announced, no matter how it got subscribed.
--
-- **What is preserved.** An explicit `notify_me` outranks an automatic source: the previous
-- ON CONFLICT overwrote `source` unconditionally, so adding a title to a list downgraded a
-- deliberate subscription into an automatic one — and then removing it from the list would have
-- retired something the user had asked for by hand. `notify_me` rows are never rewritten and
-- never auto-deactivated.
--
-- **Removal is a soft deactivation.** `is_active = false` + `deleted_at`, not a DELETE: the row
-- carries `last_notified_at`, and losing it would let a re-added title re-announce a release it
-- already announced.

alter table public.release_alerts
  add column if not exists deleted_at timestamptz;

create index if not exists release_alerts_active_idx
  on public.release_alerts (media_type, media_id)
  where is_active and deleted_at is null;

-- Rows predating the per-user country: they were all checked against Italy anyway.
update public.release_alerts set country_code = 'IT' where country_code is null;

-- ------------------------------------------------------------------------------ enrollment
--
-- Fires on INSERT and on UPDATE because a removal is a soft delete on the client side
-- (apply_mutations upserts the row with `deleted_at` set) and re-adding a title clears it again:
-- both transitions arrive as UPDATEs, and only the resurrection is an enrollment.
create or replace function public.tg_list_items_enroll_alert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_list_type text;
  v_source    text;
  v_country   text;
begin
  if new.deleted_at is not null then
    return null;  -- soft-deleted row: the retirement trigger owns this transition
  end if;

  select l.type into v_list_type
    from public.lists l
   where l.id = new.list_id
     and l.deleted_at is null;

  if v_list_type is null then
    return null;  -- item in a deleted list: not a subscription
  end if;

  v_source := case when v_list_type = 'watchlist' then 'watchlist' else 'custom_list' end;

  select p.country into v_country
    from public.user_notification_preferences p
   where p.user_id = new.user_id;

  insert into public.release_alerts as t
    (user_id, media_id, media_type, source, is_active, country_code, deleted_at)
  values
    (new.user_id, new.media_id, new.media_type, v_source, true, coalesce(v_country, 'IT'), null)
  on conflict (user_id, media_id, media_type) do update
    set is_active  = true,
        deleted_at = null,
        -- An explicit opt-in is never demoted to an automatic one.
        source     = case when t.source = 'notify_me' then t.source else excluded.source end;

  return null;
end $$;

-- ------------------------------------------------------------------------------ retirement
--
-- Both removal paths land here: apply_mutations hard-deletes on `op = 'DELETE'` and soft-deletes
-- through the upsert. The alert is retired only once the title is in none of the user's lists —
-- the same movie can sit in the watchlist and in two custom lists.
create or replace function public.tg_list_items_retire_alert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.list_items;
begin
  v_row := case when tg_op = 'DELETE' then old else new end;

  if tg_op = 'UPDATE' and v_row.deleted_at is null then
    return null;  -- still saved: nothing to retire
  end if;

  if exists (
       select 1
         from public.list_items li
         join public.lists l on l.id = li.list_id and l.deleted_at is null
        where li.user_id = v_row.user_id
          and li.media_id = v_row.media_id
          and li.media_type = v_row.media_type
          and li.deleted_at is null
          and li.id <> v_row.id
     ) then
    return null;  -- still saved somewhere else
  end if;

  update public.release_alerts
     set is_active = false,
         deleted_at = now()
   where user_id = v_row.user_id
     and media_id = v_row.media_id
     and media_type = v_row.media_type
     and source in ('watchlist', 'custom_list')  -- an explicit notify_me survives
     and is_active;

  return null;
end $$;

drop trigger if exists list_items_create_alert on public.list_items;
drop function if exists public.trg_create_alert_on_watchlist();

drop trigger if exists list_items_enroll_alert on public.list_items;
create trigger list_items_enroll_alert
  after insert or update on public.list_items
  for each row execute function public.tg_list_items_enroll_alert();

drop trigger if exists list_items_retire_alert on public.list_items;
create trigger list_items_retire_alert
  after update or delete on public.list_items
  for each row execute function public.tg_list_items_retire_alert();

revoke all on function public.tg_list_items_enroll_alert() from public;
revoke all on function public.tg_list_items_enroll_alert() from anon;
revoke all on function public.tg_list_items_enroll_alert() from authenticated;
revoke all on function public.tg_list_items_retire_alert() from public;
revoke all on function public.tg_list_items_retire_alert() from anon;
revoke all on function public.tg_list_items_retire_alert() from authenticated;

-- --------------------------------------------------------------------------------- backfill
--
-- Everything already saved, subscribed in one pass. `do nothing` on conflict: the 78 existing
-- rows (70 automatic, 8 explicit) keep their source and their last_notified_at.
insert into public.release_alerts
  (user_id, media_id, media_type, source, is_active, country_code)
select distinct on (li.user_id, li.media_id, li.media_type)
       li.user_id,
       li.media_id,
       li.media_type,
       case when l.type = 'watchlist' then 'watchlist' else 'custom_list' end,
       true,
       coalesce(p.country, 'IT')
  from public.list_items li
  join public.lists l on l.id = li.list_id and l.deleted_at is null
  left join public.user_notification_preferences p on p.user_id = li.user_id
 where li.deleted_at is null
 order by li.user_id, li.media_id, li.media_type,
          -- watchlist wins when the same title sits in several lists
          (l.type = 'watchlist') desc
on conflict (user_id, media_id, media_type) do nothing;
