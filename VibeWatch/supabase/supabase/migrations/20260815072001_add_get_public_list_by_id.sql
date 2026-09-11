-- Una lista pubblica letta per id.
--
-- `get_public_lists` sfoglia (ricerca, scope, owner) e non sa filtrare per id, e
-- `lists`/`list_items` sono own-row sotto RLS: una pagina pubblica aperta a freddo da
-- un link (/list/{id}) non ha nessun modo di leggere nome, descrizione e proprietario.
-- Gli item ce li dà già `get_list_items_with_providers`, che applica le stesse regole
-- di visibilità: questa funzione è la sua metà mancante, non una nuova politica.
--
-- Stesse condizioni di `get_public_lists`, verbatim: pubblica e non cancellata, nessun
-- blocco nei due versi, meno di tre segnalatori distinti — oppure è il proprietario a
-- guardare la propria lista.
create or replace function public.get_public_list(p_list_id uuid)
returns table (
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
set search_path to 'public', 'extensions'
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
$$;

revoke all on function public.get_public_list(uuid) from public;
grant execute on function public.get_public_list(uuid) to anon, authenticated;
