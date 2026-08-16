-- Social feed M1 — `get_public_lists` impara chi è l'autore (il gap noto di SPEC §3.7).
--
-- Una lista pubblica senza autore era accettabile quando le liste erano l'unico contenuto
-- sociale; nel tab Social accanto a un feed firmato, una card anonima stona — e l'autore è
-- anche il link al profilo, cioè il modo in cui dalle liste si arriva a seguire qualcuno.
--
-- L'identità viene da `public_profiles`, la sola superficie pubblica: se il profilo del
-- proprietario è privato (o senza username), la lista resta visibile ma l'autore resta null —
-- lo stesso contratto di `public_profiles`, la lista non tradisce chi non vuole farsi trovare.
--
-- `drop` + `create`, non `create or replace`: cambia il return type, e il replace fallirebbe.
-- Stessa coppia di drop per la riapplicabilità (run.sh applica ogni migration due volte).

drop function if exists public.get_public_lists(text, text, integer, integer, uuid);

create function public.get_public_lists(
  p_search text default null,
  p_scope  text default 'explore',
  p_limit  integer default 20,
  p_offset integer default 0,
  p_owner  uuid default null
)
returns table(
  id uuid,
  name text,
  description text,
  type text,
  updated_at timestamptz,
  item_count integer,
  cover_poster_paths text[],
  follower_count integer,
  is_following boolean,
  owner_id uuid,
  owner_username text,
  owner_display_name text,
  owner_avatar_url text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    l.id, l.name, l.description, l.type, l.updated_at,
    (select count(*)::int
       from public.list_items li
      where li.list_id = l.id and li.deleted_at is null) as item_count,
    coalesce((
      select array_agg(cov.poster_path order by cov.added_at desc)
      from (
        select li.poster_path, li.added_at
        from public.list_items li
        where li.list_id = l.id and li.deleted_at is null and li.poster_path is not null
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
    -- Blocchi nei due versi (lezione di search_users): chi ho bloccato io E chi ha
    -- bloccato me. Il secondo verso esiste solo perché la funzione è definer.
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
$$;

comment on function public.get_public_lists(text, text, integer, integer, uuid) is
  'Feed delle liste pubbliche (Explore/Followed), le liste di un utente (p_owner) e, dal '
  'social feed M1, l''identita'' dell''autore da public_profiles (null se profilo privato). '
  'Definer per escludere i blocchi nei due versi.';

-- Stessi grant della funzione che sostituisce (authenticated e service_role); il drop ha
-- portato via anche i grant, quindi si rimettono.
revoke all on function public.get_public_lists(text, text, integer, integer, uuid) from public;
revoke all on function public.get_public_lists(text, text, integer, integer, uuid) from anon;
grant execute on function public.get_public_lists(text, text, integer, integer, uuid) to authenticated;
grant execute on function public.get_public_lists(text, text, integer, integer, uuid) to service_role;
