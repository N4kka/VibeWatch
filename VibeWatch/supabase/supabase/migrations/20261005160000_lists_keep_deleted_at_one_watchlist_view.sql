-- lists: a write that doesn't carry deleted_at no longer un-deletes the row, and a user keeps at
-- most one live copy of the watchlist.
--
-- 1. The upsert ran `deleted_at = excluded.deleted_at`, and no client sends deleted_at on an
--    INSERT/UPDATE (deletes go through op DELETE). So any write to a list deleted elsewhere — iOS
--    re-inserting at login the custom lists it still holds locally but did not find in the
--    (deleted_at IS NULL) fetch, a rename or visibility toggle from a device that missed the
--    delete — brought the list back. Same splice as the source_list_* one (20260911120000):
--    a key the record doesn't carry keeps the stored value.
--
-- 2. Every "duplicate the watchlist" tap on old iOS builds made a new live copy; there was no
--    constraint behind the clients' reuse check. One live copy per user, enforced like the one
--    system list per type: a second copy is a silent no-op inside apply_mutations, not a failed
--    batch (a failed batch would be poison to the clients' outboxes).
--
-- No md5 guard on the source: this follows 20261005120000 and the live hash after it was not
-- recorded. The anchor is checked to occur exactly once instead, and the splice is idempotent.
-- Spliced onto the live prosrc, never rewritten (see the deploy notes).

-- 2a. Refuse to build the index over existing duplicates: which copy to keep is a decision, not
-- something a migration should take silently.
do $check$
declare
  v_dupes int;
begin
  select count(*) into v_dupes
  from (
    select user_id
    from public.lists
    where type = 'custom' and source_list_type = 'watchlist' and deleted_at is null
    group by user_id
    having count(*) > 1
  ) d;
  if v_dupes > 0 then
    raise exception '% user(s) have more than one live watchlist copy; soft-delete the extras first', v_dupes;
  end if;
end
$check$;

create unique index if not exists idx_lists_one_active_watchlist_view
  on public.lists (user_id)
  where type = 'custom' and source_list_type = 'watchlist' and deleted_at is null;

-- 1 + 2b. apply_mutations.
do $splice$
declare
  v_src text;
  v_def text;
  v_old text := 'deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;
          exception when unique_violation then
            if sqlerrm not like ''%idx_lists_one_active_default_per_user_type%'' then';
  v_new text := 'deleted_at = case when rec ? ''deleted_at'' then excluded.deleted_at else t.deleted_at end,
              synced_at = now()
            where t.user_id = v_uid;
          exception when unique_violation then
            if sqlerrm not like ''%idx_lists_one_active_default_per_user_type%''
               and sqlerrm not like ''%idx_lists_one_active_watchlist_view%'' then';
begin
  select p.prosrc, pg_get_functiondef(p.oid) into v_src, v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'apply_mutations';

  if position(v_new in v_src) > 0 then
    return; -- already applied
  end if;
  if (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'apply_mutations: splice anchor not found exactly once';
  end if;

  execute replace(v_def, v_old, v_new);
end
$splice$;
