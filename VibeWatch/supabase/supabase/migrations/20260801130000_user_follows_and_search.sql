-- SPEC v3 §3.6/§3.7 — `user_follows` e la ricerca utenti.
--
-- **Perche' `search_users` e' `security definer`.** Deve escludere i blocchi *in entrambe le
-- direzioni* (§3.7), ma `user_blocks` ha `blocks_select_own`: il verso "mi ha bloccato" e'
-- invisibile al chiamante per costruzione. Un `security invoker` vedrebbe solo meta' dei blocchi
-- e mostrerebbe a B il profilo di chi l'ha bloccato. Come per `expand_seen_shows_to_watch_events`,
-- il punto che conta non e' l'etichetta: **non esiste un parametro con l'identita'** — il
-- chiamante e' `auth.uid()`, sempre.
--
-- **Perche' il blocco si applica anche in scrittura.** L'esclusione dei bloccati nella sola
-- ricerca sarebbe `username_reserved` consultata solo dalle funzioni che propongono: chi passa
-- dalla porta principale (un INSERT su `user_follows`) seguirebbe comunque chi l'ha bloccato, e
-- comparirebbe nella sua lista follower. La RLS non basta: una policy del follower non puo'
-- leggere il verso "mi ha bloccato" di `user_blocks`. Il posto e' un trigger `security definer`,
-- l'unico punto non scavalcabile.

-- ------------------------------------------------------------------------- user_follows
--
-- La forma e' quella di §3.6, identica alla spec: PK composita, niente id sintetico — un follow
-- e' la coppia, e l'idempotenza della coppia e' gratis. Soft delete come `user_blocks`: un
-- unfollow e' `deleted_at`, e il re-follow riusa la riga.
create table if not exists public.user_follows (
  follower_id  uuid not null references auth.users (id) on delete cascade,
  followee_id  uuid not null references auth.users (id) on delete cascade,
  created_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  synced_at    timestamptz,
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

comment on table public.user_follows is
  'SPEC v3 §3.6: chi segue chi. Soft delete; il re-follow riusa la riga. '
  'Sync: union (§4), mai perdere un follow.';

-- La PK copre "chi seguo"; questo copre "chi mi segue" (liste follower e contatori di §9.3).
create index if not exists user_follows_followee
  on public.user_follows (followee_id) where deleted_at is null;

alter table public.user_follows enable row level security;

-- Si vedono le righe in cui si e' uno dei due capi: le mie uscite e i miei follower. Scrive solo
-- il follower — seguire qualcuno e' un atto di chi segue, in tutte e due le direzioni (insert e
-- soft delete via update).
drop policy if exists follows_select_own on public.user_follows;
create policy follows_select_own on public.user_follows
  for select using ((select auth.uid()) in (follower_id, followee_id));

drop policy if exists follows_insert_own on public.user_follows;
create policy follows_insert_own on public.user_follows
  for insert with check ((select auth.uid()) = follower_id);

drop policy if exists follows_update_own on public.user_follows;
create policy follows_update_own on public.user_follows
  for update using ((select auth.uid()) = follower_id)
             with check ((select auth.uid()) = follower_id);

revoke all on public.user_follows from public;
revoke all on public.user_follows from anon;
grant select, insert, update on public.user_follows to authenticated;

-- ------------------------------------------------------- il blocco vale anche in scrittura
--
-- `before insert or update`: vale per il follow nuovo e per il re-follow (deleted_at che torna
-- null). Su una riga gia' cancellata non c'e' niente da vietare.
create or replace function public.tg_user_follows_blocked()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is null
     and exists (
       select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = new.follower_id and b.blocked_user_id = new.followee_id)
            or (b.user_id = new.followee_id and b.blocked_user_id = new.follower_id))
     ) then
    raise exception 'follow_blocked' using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists user_follows_blocked on public.user_follows;
create trigger user_follows_blocked
  before insert or update on public.user_follows
  for each row execute function public.tg_user_follows_blocked();

-- ------------------------------------------------------------------------- search_users
--
-- Legge da `public_profiles` — la sola superficie pubblica — quindi niente email, niente profili
-- privati, niente profili senza username. `ilike` e non l'operatore `%` di pg_trgm: la soglia di
-- similarita' (0.3) boccerebbe le query corte della ricerca incrementale ("ann" su "anna_rossi"),
-- mentre `ilike` usa comunque gli indici GIN trigram gia' esistenti su `profiles`. La similarita'
-- serve per l'**ordine**, dove una soglia non c'e'.
--
-- `%`, `_` e `\` nella query si cercano come caratteri, non come jolly: `_` dentro uno username
-- e' la norma, e senza escape una query di soli underscore combacerebbe con tutto.
create or replace function public.search_users(p_query text, p_limit integer default 20)
returns setof public.public_profiles
language sql
stable
security definer
set search_path = public
as $$
  with q as (
    select btrim(coalesce(p_query, '')) as raw,
           replace(replace(replace(btrim(coalesce(p_query, '')),
             '\', '\\'), '%', '\%'), '_', '\_') as esc
  )
  select pp.*
  from public.public_profiles pp, q
  where q.raw <> ''
    and (pp.username::text ilike '%' || q.esc || '%' escape '\'
         or coalesce(pp.display_name, '') ilike '%' || q.esc || '%' escape '\')
    and not exists (
      select 1 from public.user_blocks b
       where b.deleted_at is null
         and ((b.user_id = (select auth.uid()) and b.blocked_user_id = pp.id)
           or (b.user_id = pp.id and b.blocked_user_id = (select auth.uid())))
    )
  order by greatest(extensions.similarity(pp.username::text, q.raw),
                    extensions.similarity(coalesce(pp.display_name, ''), q.raw)) desc,
           pp.username
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

comment on function public.search_users(text, integer) is
  'SPEC v3 §3.7: ricerca utenti su username e display_name, blocchi esclusi nei due versi. '
  'Definer perche'' il verso "mi ha bloccato" e'' invisibile al chiamante; l''identita'' e'' '
  'auth.uid(), mai un parametro.';

-- La lezione di `import_touched_shows`: revocare a PUBLIC non toglie i grant espliciti che i
-- default privileges di Supabase danno ad anon/authenticated. Tutti e tre, e fa fede `proacl`.
revoke all on function public.search_users(text, integer) from public;
revoke all on function public.search_users(text, integer) from anon;
revoke all on function public.search_users(text, integer) from authenticated;
grant execute on function public.search_users(text, integer) to authenticated;

revoke all on function public.tg_user_follows_blocked() from public;
revoke all on function public.tg_user_follows_blocked() from anon;
revoke all on function public.tg_user_follows_blocked() from authenticated;
