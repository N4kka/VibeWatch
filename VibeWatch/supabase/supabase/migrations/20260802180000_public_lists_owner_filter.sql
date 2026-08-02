-- SPEC v3 §9.3, ultimo bullet — "Liste pubbliche dell'utente" nel profilo altrui.
--
-- `get_public_lists` serviva solo il feed (Explore/Followed); il profilo ha bisogno delle
-- liste DI un utente. Un parametro nuovo invece di una funzione nuova: stessa proiezione,
-- stesse difese (is_public, soglia report, blocchi), e il client che pagina il feed non
-- cambia — con `p_owner` null il comportamento è quello di prima.
--
-- Due cose cambiano davvero, ed entrambe hanno un perché:
--
--   * **`drop` + `create`, non `create or replace`**: aggiungere un parametro cambia la
--     firma, e il replace creerebbe un OVERLOAD accanto al vecchio — due funzioni omonime
--     che PostgREST non saprebbe distinguere (ambiguous function). La coppia vive nella
--     stessa transazione: nessuna finestra senza funzione.
--   * **i blocchi ora escludono NEI DUE VERSI** — la lezione di `search_users`: il verso
--     "mi ha bloccato" è invisibile a un invoker per costruzione (`blocks_select_own`), e
--     questa funzione è `security definer` proprio per poterlo leggere. Prima escludeva
--     solo chi avevo bloccato io: le liste di chi MI ha bloccato comparivano nel feed —
--     mostrare a B i contenuti di A che l'ha bloccato è ciò che il blocco esiste per
--     impedire. Vale per il feed e, a maggior ragione, per il profilo.

drop function if exists public.get_public_lists(text, text, integer, integer);
-- Anche la firma nuova, per la riapplicabilità (run.sh applica ogni migration due volte):
-- al secondo giro la vecchia non c'è più e senza questo il `create` troverebbe la nuova.
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
  is_following boolean
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
    ) as is_following
  from public.lists l
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
  'Feed delle liste pubbliche (Explore/Followed) e, con p_owner, le liste pubbliche di un '
  'utente per il suo profilo (§9.3). Definer per escludere i blocchi nei due versi.';

-- Stessi grant della funzione che sostituisce (verificati su proacl in produzione:
-- authenticated e service_role). Il drop ha portato via anche i grant, quindi si rimettono.
revoke all on function public.get_public_lists(text, text, integer, integer, uuid) from public;
revoke all on function public.get_public_lists(text, text, integer, integer, uuid) from anon;
grant execute on function public.get_public_lists(text, text, integer, integer, uuid) to authenticated;
grant execute on function public.get_public_lists(text, text, integer, integer, uuid) to service_role;
