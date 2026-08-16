-- SEC: cross-user write through apply_mutations -> list_items.
--
-- apply_mutations is SECURITY DEFINER, so it bypasses RLS and has to enforce ownership itself.
-- It checked `record.user_id = auth.uid()` but never checked `record.list_id`, so a caller could
-- write a row carrying their own user_id into *someone else's* list. get_list_items_with_providers
-- (also SECURITY DEFINER) returns every row matching the list_id without looking at li.user_id,
-- so the injected item showed up for everyone viewing that public list — with attacker-controlled
-- title, overview and poster_path.
--
-- The victim could not remove it either: both the RLS DELETE policy and the apply_mutations DELETE
-- branch are scoped to the row's own user_id, which is the attacker.
--
-- Reproduced before the fix: inserting into a public list owned by another account took it from
-- 128 to 129 items, all 129 returned by the public RPC. Verified 0 pre-existing mismatched rows,
-- so nothing was exploited in the wild.
--
-- Two layers: refuse the write, and refuse to serve items that do not belong to the list owner.

create or replace function public.apply_mutations(batch jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
  declare
    item jsonb;
    op text;
    tbl text;
    rec jsonb;
    rec_id text;
    v_uid uuid := (select auth.uid());
  begin
    if v_uid is null then
      raise exception 'unauthenticated';
    end if;

    for item in select * from jsonb_array_elements(batch)
    loop
      op := item->>'op';
      tbl := item->>'table';
      rec := item->'record';
      rec_id := item->>'id';

      if op in ('INSERT','UPDATE')
         and (rec->>'user_id') is distinct from v_uid::text then
        continue;
      end if;

      -- lists (id/user_id sono uuid → cast espliciti)
      if tbl = 'lists' then
        if op in ('INSERT','UPDATE') then
          insert into public.lists as t
            (id, user_id, name, description, type, is_public, created_at, updated_at, deleted_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'user_id')::uuid, rec->>'name', rec->>'description', rec->>'type',
             (coalesce((rec->>'is_public')::boolean, false) and (rec->>'type') = 'custom'),
             (rec->>'created_at')::timestamptz, (rec->>'updated_at')::timestamptz,
             (rec->>'deleted_at')::timestamptz, now())
          on conflict (id) do update set
            name = excluded.name,
            description = excluded.description,
            type = excluded.type,
            is_public = (coalesce((rec->>'is_public')::boolean, t.is_public) and excluded.type = 'custom'),
            updated_at = excluded.updated_at,
            deleted_at = excluded.deleted_at,
            synced_at = now()
          where t.user_id = v_uid;
        elsif op = 'DELETE' then
          update public.lists set deleted_at = now(), synced_at = now()
          where id = rec_id::uuid and user_id = v_uid;
        end if;
      end if;

      -- list_items (id/list_id/user_id uuid; NO colonna updated_at)
      if tbl = 'list_items' then
        if op in ('INSERT','UPDATE') then
          -- The destination list must belong to the caller. Owning the *row* is not enough:
          -- without this, a row with a legitimate user_id lands inside another user's list.
          -- A null or unknown list_id fails the check and the mutation is dropped.
          if not exists (
            select 1 from public.lists l
            where l.id = nullif(rec->>'list_id','')::uuid
              and l.user_id = v_uid
          ) then
            continue;
          end if;

          insert into public.list_items as t
            (id, list_id, user_id, media_id, media_type, title, poster_path, runtime,
             vote_average, vote_count, origin_country, release_date, genres, overview,
             added_at, created_at, deleted_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'list_id')::uuid, (rec->>'user_id')::uuid, (rec->>'media_id')::int, rec->>'media_type',
             rec->>'title', rec->>'poster_path', nullif(rec->>'runtime','')::int,
             nullif(rec->>'vote_average','')::numeric, nullif(rec->>'vote_count','')::int,
             case when jsonb_typeof(rec->'origin_country') = 'array' then array(select jsonb_array_elements_text(rec->'origin_country')) else null end,
             rec->>'release_date',
             case when jsonb_typeof(rec->'genres') = 'array' then array(select (jsonb_array_elements(rec->'genres'))::int) else null end,
             rec->>'overview',
             (rec->>'added_at')::timestamptz,
             (rec->>'created_at')::timestamptz,
             (rec->>'deleted_at')::timestamptz,
             now())
          on conflict (id) do update set
            list_id = excluded.list_id,
            user_id = excluded.user_id,
            media_id = excluded.media_id,
            media_type = excluded.media_type,
            title = excluded.title,
            poster_path = excluded.poster_path,
            runtime = excluded.runtime,
            vote_average = excluded.vote_average,
            vote_count = excluded.vote_count,
            origin_country = excluded.origin_country,
            release_date = excluded.release_date,
            genres = excluded.genres,
            overview = excluded.overview,
            added_at = excluded.added_at,
            deleted_at = excluded.deleted_at,
            synced_at = now()
          where t.user_id = v_uid;
        elsif op = 'DELETE' then
          delete from public.list_items where id = rec_id::uuid and user_id = v_uid;
        end if;
      end if;

      -- list_follows
      if tbl = 'list_follows' then
        if op in ('INSERT','UPDATE') then
          insert into public.list_follows as t
            (id, user_id, list_id, created_at, deleted_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'user_id')::uuid, (rec->>'list_id')::uuid,
             (rec->>'created_at')::timestamptz, (rec->>'deleted_at')::timestamptz, now())
          on conflict (id) do update set
            deleted_at = excluded.deleted_at,
            synced_at = now()
          where t.user_id = v_uid;
        elsif op = 'DELETE' then
          update public.list_follows set deleted_at = now(), synced_at = now()
          where id = rec_id::uuid and user_id = v_uid;
        end if;
      end if;

      -- user_blocks
      if tbl = 'user_blocks' then
        if op in ('INSERT','UPDATE') then
          insert into public.user_blocks as t
            (id, user_id, blocked_user_id, created_at, deleted_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'user_id')::uuid, (rec->>'blocked_user_id')::uuid,
             (rec->>'created_at')::timestamptz, (rec->>'deleted_at')::timestamptz, now())
          on conflict (id) do update set
            deleted_at = excluded.deleted_at,
            synced_at = now()
          where t.user_id = v_uid;
        elsif op = 'DELETE' then
          update public.user_blocks set deleted_at = now(), synced_at = now()
          where id = rec_id::uuid and user_id = v_uid;
        end if;
      end if;

      -- list_reports (insert-only, idempotente per coppia)
      if tbl = 'list_reports' then
        if op in ('INSERT','UPDATE') then
          insert into public.list_reports as t
            (id, user_id, list_id, reason, created_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'user_id')::uuid, (rec->>'list_id')::uuid, rec->>'reason',
             (rec->>'created_at')::timestamptz, now())
          on conflict (user_id, list_id) do nothing;
        end if;
      end if;

    end loop;
  end;
$function$;

-- The branches for user_preferences, user_daily_quota, user_ai_token_usage, user_clip_history,
-- notifications and user_devices were removed rather than carried forward. Every one of them
-- referenced columns those tables do not have (`updated_at` on notifications, `device_id` on
-- user_devices, `tokens_used` and an `id` column on user_ai_token_usage) or passed text into uuid
-- columns, so all six raised at runtime and none is reachable: the client's outbox never queues
-- those tables. Keeping them would only preserve the illusion that those paths sync.

-- Defence in depth: never serve an item that does not belong to the list's owner, so any row
-- injected before the fix above stops being visible.
create or replace function public.get_list_items_with_providers(p_list_id uuid, p_country text)
returns table(item jsonb, providers jsonb)
language sql
stable
security definer
set search_path to 'public', 'extensions'
as $function$
  select
    to_jsonb(li.*) as item,
    coalesce(
      jsonb_agg(to_jsonb(ma.*)) filter (where ma.id is not null),
      '[]'::jsonb
    ) as providers
  from public.lists l
  join public.list_items li
    on li.list_id = l.id
   and li.deleted_at is null
   and li.user_id = l.user_id
  left join public.media_availability ma
    on ma.media_id = li.media_id
   and ma.media_type = li.media_type
   and ma.country_code = p_country
  where l.id = p_list_id
    and l.deleted_at is null
    and (
      l.user_id = (select auth.uid())
      or (
        l.is_public
        and not exists (
          select 1 from public.user_blocks b
          where b.user_id = (select auth.uid())
            and b.blocked_user_id = l.user_id
            and b.deleted_at is null
        )
        and (select count(distinct r.user_id) from public.list_reports r where r.list_id = l.id) < 3
      )
    )
  group by li.id;
$function$;

-- apply_mutations derives the user from the session and rejects a null auth.uid(), but there is
-- no reason for the anon role to hold EXECUTE on it at all.
revoke all on function public.apply_mutations(jsonb) from anon;
