-- The public watchlist becomes a live pointer instead of a copy.
--
-- "Crea lista pubblica da questa" used to copy the watchlist into a custom list and keep the copy
-- in sync from the client. It never could: watchlist TV shows are tracking state, not list_items,
-- so marking an episode watched never left the copy; other devices and the web never propagated
-- at all; and renaming the copy erased its link. A custom list with source_list_type='watchlist'
-- now owns no items: every public read resolves to the owner's watchlist (movies from list_items,
-- TV from tv_show_state with the same bucket rule as the iOS fusion).

-- 1. The items of a list, as list_items rows. Internal: only the definer RPCs below call it.
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
  -- Watchlist films. Legacy TV rows still in list_items are skipped, as both clients do.
  select li.*
  from public.lists w
  join public.list_items li on li.list_id = w.id and li.deleted_at is null and li.media_type = 'movie'
  where p_list.source_list_type = 'watchlist'
    and w.user_id = p_list.user_id
    and w.type = 'watchlist'
    and w.deleted_at is null
  union all
  -- Watchlist series: LocalTrackingRepository.fusedListRows minus the "seen" rows.
  select (jsonb_populate_record(null::public.list_items, jsonb_build_object(
    'id', md5(p_list.id::text || ':tv:' || s.tmdb_show_id)::uuid,
    'list_id', p_list.id,
    'user_id', s.user_id,
    'media_id', s.tmdb_show_id,
    'media_type', 'tv',
    'title', sh.name,
    'poster_path', sh.poster_path,
    'added_at', s.updated_at,
    'origin_country', sh.origin_country,
    'release_date', sh.first_air_date::text,
    'genres', sh.genres,
    'created_at', s.updated_at
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

-- It takes any lists row and bypasses RLS: callable directly it would read anyone's tracking.
revoke all on function public.list_items_for(public.lists) from public, anon, authenticated;

-- 2. The four public reads, unchanged except for where the items come from.
create or replace function public.get_public_lists(p_search text default null::text, p_scope text default 'explore'::text, p_limit integer default 20, p_offset integer default 0, p_owner uuid default null::uuid)
 returns table(id uuid, name text, description text, type text, updated_at timestamp with time zone, item_count integer, cover_poster_paths text[], follower_count integer, is_following boolean, owner_id uuid, owner_username text, owner_display_name text, owner_avatar_url text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select
    l.id, l.name, l.description, l.type, l.updated_at,
    (select count(*)::int from public.list_items_for(l)) as item_count,
    coalesce((
      select array_agg(cov.poster_path order by cov.added_at desc)
      from (
        select li.poster_path, li.added_at
        from public.list_items_for(l) li
        where li.poster_path is not null
        order by li.added_at desc
        limit 4
      ) cov
    ), '{}'::text[]) as cover_poster_paths,
    (select count(*)::int
       from public.list_follows f
      where f.list_id = l.id and f.deleted_at is null) as follower_count,
    exists(
      select 1 from public.list_follows f
      where f.list_id = l.id and f.user_id = (select auth.uid()) and f.deleted_at is null
    ) as is_following,
    pp.id as owner_id,
    pp.username::text as owner_username,
    pp.display_name as owner_display_name,
    pp.avatar_url as owner_avatar_url
  from public.lists l
  left join public.public_profiles pp on pp.id = l.user_id
  where l.is_public
    and l.deleted_at is null
    and (p_owner is null or l.user_id = p_owner)
    and (p_search is null or p_search = '' or l.name ilike '%' || p_search || '%')
    and not exists (
      select 1 from public.user_blocks b
      where b.deleted_at is null
        and ((b.user_id = (select auth.uid()) and b.blocked_user_id = l.user_id)
          or (b.user_id = l.user_id and b.blocked_user_id = (select auth.uid())))
    )
    and (
      l.user_id = (select auth.uid())
      or (select count(distinct r.user_id) from public.list_reports r where r.list_id = l.id) < 3
    )
    and (
      p_scope is distinct from 'followed'
      or exists (
        select 1 from public.list_follows f
        where f.list_id = l.id and f.user_id = (select auth.uid()) and f.deleted_at is null
      )
    )
  order by follower_count desc, l.updated_at desc
  limit greatest(coalesce(p_limit, 20), 0)
  offset greatest(coalesce(p_offset, 0), 0);
$function$;

create or replace function public.get_public_list(p_list_id uuid)
 returns table(id uuid, name text, description text, type text, updated_at timestamp with time zone, item_count integer, cover_poster_paths text[], follower_count integer, is_following boolean, owner_id uuid, owner_username text, owner_display_name text, owner_avatar_url text)
 language sql
 stable security definer
 set search_path to 'public', 'extensions'
as $function$
  select
    l.id, l.name, l.description, l.type, l.updated_at,
    (select count(*)::int from public.list_items_for(l)) as item_count,
    coalesce((
      select array_agg(cov.poster_path order by cov.added_at desc)
      from (
        select li.poster_path, li.added_at
        from public.list_items_for(l) li
        where li.poster_path is not null
        order by li.added_at desc
        limit 4
      ) cov
    ), '{}'::text[]) as cover_poster_paths,
    (select count(*)::int
       from public.list_follows f
      where f.list_id = l.id and f.deleted_at is null) as follower_count,
    exists(
      select 1 from public.list_follows f
      where f.list_id = l.id and f.user_id = (select auth.uid()) and f.deleted_at is null
    ) as is_following,
    pp.id as owner_id,
    pp.username::text as owner_username,
    pp.display_name as owner_display_name,
    pp.avatar_url as owner_avatar_url
  from public.lists l
  left join public.public_profiles pp on pp.id = l.user_id
  where l.id = p_list_id
    and l.deleted_at is null
    and not exists (
      select 1 from public.user_blocks b
      where b.deleted_at is null
        and ((b.user_id = (select auth.uid()) and b.blocked_user_id = l.user_id)
          or (b.user_id = l.user_id and b.blocked_user_id = (select auth.uid())))
    )
    and (
      l.user_id = (select auth.uid())
      or (
        l.is_public
        and (select count(distinct r.user_id) from public.list_reports r where r.list_id = l.id) < 3
      )
    );
$function$;

create or replace function public.get_list_items_with_providers(p_list_id uuid, p_country text)
 returns table(item jsonb, providers jsonb)
 language sql
 stable security definer
 set search_path to 'public', 'extensions'
as $function$
  -- Providers per item in a subquery: grouping by li.id only worked while li was a table with
  -- a primary key, and a function's rows have none.
  select
    to_jsonb(li.*) as item,
    coalesce((
      select jsonb_agg(to_jsonb(ma.*))
      from public.media_availability ma
      where ma.media_id = li.media_id
        and ma.media_type = li.media_type
        and ma.country_code = p_country
    ), '[]'::jsonb) as providers
  from public.lists l
  cross join lateral public.list_items_for(l) li
  where l.id = p_list_id
    and l.deleted_at is null
    and li.user_id = l.user_id
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
    );
$function$;

create or replace function public.get_activity_feed(p_scope text default 'following'::text, p_user uuid default null::uuid, p_before timestamp with time zone default null::timestamp with time zone, p_before_id uuid default null::uuid, p_limit integer default 20, p_activity_id uuid default null::uuid)
 returns table(activity_id uuid, user_id uuid, username text, display_name text, avatar_url text, activity_type text, media_type text, tmdb_id integer, episode_count integer, rating smallint, review_id uuid, review_content text, contains_spoilers boolean, list_id uuid, list_name text, list_cover_poster_paths text[], title text, poster_path text, occurred_at timestamp with time zone, like_count integer, comment_count integer, liked_by_me boolean)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select
    a.id as activity_id,
    a.user_id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    a.activity_type,
    a.media_type,
    a.tmdb_id,
    a.episode_count,
    a.rating,
    a.review_id,
    case when a.review_id is not null
          and a.user_id <> (select auth.uid())
          and (select count(distinct cr.reporter_id) from public.content_reports cr
                where cr.content_type = 'review' and cr.content_id = a.review_id) >= 3
         then null else v.content end as review_content,
    case when a.review_id is not null
          and a.user_id <> (select auth.uid())
          and (select count(distinct cr.reporter_id) from public.content_reports cr
                where cr.content_type = 'review' and cr.content_id = a.review_id) >= 3
         then null else v.contains_spoilers end as contains_spoilers,
    a.list_id,
    l.name as list_name,
    case when a.list_id is null then null
         else coalesce((
           select array_agg(cov.poster_path order by cov.added_at desc)
           from (
             select li.poster_path, li.added_at
             from public.list_items_for(l) li
             where li.poster_path is not null
             order by li.added_at desc
             limit 4
           ) cov
         ), '{}'::text[])
    end as list_cover_poster_paths,
    a.title,
    a.poster_path,
    a.occurred_at,
    (select count(*)::int from public.activity_likes al
      where al.activity_id = a.id and al.deleted_at is null) as like_count,
    (select count(*)::int from public.activity_comments ac
      where ac.activity_id = a.id and ac.deleted_at is null) as comment_count,
    exists(select 1 from public.activity_likes al
            where al.activity_id = a.id and al.user_id = (select auth.uid())
              and al.deleted_at is null) as liked_by_me
  from public.activities a
  join public.profiles p on p.id = a.user_id
  left join public.user_reviews v on v.id = a.review_id and v.deleted_at is null
  left join public.lists l on l.id = a.list_id and l.deleted_at is null
  where a.deleted_at is null
    and a.hidden_at is null
    and (
      a.user_id = (select auth.uid())
      or (p.deleted_at is null
          and p.username is not null
          and p.is_profile_public
          and p.activity_feed_enabled
          and p.feed_activated_at is not null)
    )
    and (
      a.user_id = (select auth.uid())
      or not exists (
        select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = (select auth.uid()) and b.blocked_user_id = a.user_id)
            or (b.user_id = a.user_id and b.blocked_user_id = (select auth.uid())))
      )
    )
    and (
      a.activity_type <> 'list_created'
      or a.user_id = (select auth.uid())
      or (select count(distinct r.user_id) from public.list_reports r where r.list_id = a.list_id) < 3
    )
    and (a.activity_type <> 'list_created' or (l.id is not null and l.is_public))
    and (p_activity_id is null or a.id = p_activity_id)
    and (
      p_activity_id is not null
      or case p_scope
           when 'community' then true
           when 'user' then a.user_id = p_user
           else a.user_id = (select auth.uid())
                or exists (
                  select 1 from public.user_follows f
                  where f.follower_id = (select auth.uid())
                    and f.followee_id = a.user_id
                    and f.deleted_at is null
                )
         end
    )
    and (
      p_activity_id is not null
      or p_before is null
      or a.occurred_at < p_before
      or (a.occurred_at = p_before and p_before_id is not null and a.id < p_before_id)
    )
  order by a.occurred_at desc, a.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$function$;

-- 3. apply_mutations: a lists write that doesn't carry the link keeps it. Every rename and
-- visibility toggle used to send no source_list_* (or ""), which the upsert turned into NULL.
-- Spliced onto the live prosrc, never rewritten (see the deploy notes).
do $splice$
declare
  v_src text;
  v_def text;
  v_old text := 'source_list_id = excluded.source_list_id,
              source_list_type = excluded.source_list_type,';
  v_new text := 'source_list_id = case when rec ? ''source_list_id'' then excluded.source_list_id else t.source_list_id end,
              source_list_type = case when rec ? ''source_list_type'' then excluded.source_list_type else t.source_list_type end,';
begin
  select p.prosrc, pg_get_functiondef(p.oid) into v_src, v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'apply_mutations';

  if position(v_new in v_src) > 0 then
    return; -- already applied
  end if;
  if md5(v_src) <> 'dc9559362529f61622d98ca8bacf6b75' then
    raise exception 'apply_mutations changed since this splice was written (md5 %)', md5(v_src);
  end if;
  if (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'apply_mutations: splice anchor not found exactly once';
  end if;

  execute replace(v_def, v_old, v_new);
end
$splice$;
