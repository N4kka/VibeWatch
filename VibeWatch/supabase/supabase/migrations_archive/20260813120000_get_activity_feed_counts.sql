-- Social feed M2 — `get_activity_feed` smette di fingere: conteggi veri e velo sui report.
--
-- Il contratto era pronto dalla M1 (like_count/comment_count/liked_by_me nel return type, a
-- zero): ora che activity_likes e activity_comments esistono, i placeholder diventano subquery
-- e il client non cambia di una virgola — era il punto di metterle nel contratto da subito.
--
-- **La review segnalata si vela, la card resta.** A 3 segnalatori distinti spariscono testo e
-- flag spoiler, ma il VOTO no: la segnalazione riguarda il testo, non il giudizio — nascondere
-- la card intera punirebbe contenuto mai segnalato. Il proprietario continua a vedere tutto,
-- come per le liste. Stessa firma, CREATE OR REPLACE: nessuna finestra senza funzione.

create or replace function public.get_activity_feed(
  p_scope     text default 'following',
  p_user      uuid default null,
  p_before    timestamptz default null,
  p_before_id uuid default null,
  p_limit     integer default 20
)
returns table(
  activity_id uuid,
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  activity_type text,
  media_type text,
  tmdb_id integer,
  episode_count integer,
  rating smallint,
  review_id uuid,
  review_content text,
  contains_spoilers boolean,
  list_id uuid,
  list_name text,
  list_cover_poster_paths text[],
  title text,
  poster_path text,
  occurred_at timestamptz,
  like_count integer,
  comment_count integer,
  liked_by_me boolean
)
language sql
stable
security definer
set search_path = public
as $$
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
             from public.list_items li
             where li.list_id = a.list_id and li.deleted_at is null and li.poster_path is not null
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
    and (
      case p_scope
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
      p_before is null
      or a.occurred_at < p_before
      or (a.occurred_at = p_before and p_before_id is not null and a.id < p_before_id)
    )
  order by a.occurred_at desc, a.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

comment on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer) is
  'Social feed M2: conteggi like/commenti veri e velo sulle review a >=3 report (testo e flag '
  'spoiler null, voto e card intatti; il proprietario vede tutto). Firma invariata dalla M1.';
