-- Social feed M1 — `get_activity_feed`: la superficie di lettura del feed.
--
-- Definer per le stesse tre ragioni di `get_public_lists`: le tabelle sorgente sono owner-only
-- per RLS, il verso "mi ha bloccato" è invisibile a un invoker per costruzione, e l'identità è
-- `auth.uid()`, mai un parametro.
--
-- **Il cancello dell'autore.** Un'attività compare solo se il suo autore ha: profilo pubblico,
-- username, feed abilitato E consenso stampato (`feed_activated_at`). A se stessi si è sempre
-- visibili — la propria card nel feed è la conferma che il feed funziona, e con 30 MAU è anche
-- metà del contenuto di Following.
--
-- **Paginazione keyset** su (occurred_at, id), non offset: le card nuove in testa non fanno
-- scivolare doppioni nelle pagine successive.
--
-- **like/comment: colonne già nel contratto, valori M2.** Il client si scrive oggi contro la
-- forma definitiva; quando activity_likes/activity_comments esisteranno (M2), questa funzione
-- si sostituisce con i conteggi veri e il client non cambia. Stesso discorso per il filtro
-- report sulle review: content_reports nasce in M2 insieme alla UI di report — un filtro su
-- una tabella che non può avere righe sarebbe codice morto travestito da difesa.

drop function if exists public.get_activity_feed(text, uuid, timestamptz, uuid, integer);

create function public.get_activity_feed(
  p_scope     text default 'following',   -- 'following' | 'community' | 'user'
  p_user      uuid default null,          -- obbligatorio con p_scope = 'user'
  p_before    timestamptz default null,   -- cursore keyset (occorre insieme a p_before_id)
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
    v.content as review_content,
    v.contains_spoilers,
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
    0 as like_count,       -- M2: count su activity_likes
    0 as comment_count,    -- M2: count su activity_comments
    false as liked_by_me   -- M2: exists su activity_likes
  from public.activities a
  join public.profiles p on p.id = a.user_id
  left join public.user_reviews v on v.id = a.review_id and v.deleted_at is null
  left join public.lists l on l.id = a.list_id and l.deleted_at is null
  where a.deleted_at is null
    -- Il cancello dell'autore: pubblico + consenso, oppure se stessi.
    and (
      a.user_id = (select auth.uid())
      or (p.deleted_at is null
          and p.username is not null
          and p.is_profile_public
          and p.activity_feed_enabled
          and p.feed_activated_at is not null)
    )
    -- Blocchi nei due versi (lezione di search_users), mai contro se stessi.
    and (
      a.user_id = (select auth.uid())
      or not exists (
        select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = (select auth.uid()) and b.blocked_user_id = a.user_id)
            or (b.user_id = a.user_id and b.blocked_user_id = (select auth.uid())))
      )
    )
    -- La card di una lista nascosta dai report sparisce anche dal feed: stessa soglia (3
    -- segnalatori distinti) e stessa eccezione per il proprietario di get_public_lists.
    and (
      a.activity_type <> 'list_created'
      or a.user_id = (select auth.uid())
      or (select count(distinct r.user_id) from public.list_reports r where r.list_id = a.list_id) < 3
    )
    -- Una card lista la cui lista è sparita o tornata privata non deve sopravvivere alla
    -- corsa col trigger che la tombstona.
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
    -- Cursore keyset: strettamente prima di (p_before, p_before_id).
    and (
      p_before is null
      or a.occurred_at < p_before
      or (a.occurred_at = p_before and p_before_id is not null and a.id < p_before_id)
    )
  order by a.occurred_at desc, a.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

comment on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer) is
  'Social feed M1: il feed (following/community) e l''attivita'' di un profilo (user). Definer '
  'per RLS owner-only sulle sorgenti e blocchi nei due versi. Keyset su (occurred_at, id). '
  'like/comment nel contratto dalla nascita, conteggi veri in M2.';

revoke all on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer) from public;
revoke all on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer) from anon;
revoke all on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer) from authenticated;
grant execute on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer) to authenticated;
