-- Social feed M2 — like e commenti sulle card del feed.
--
-- **Perché RPC definer e non rami in apply_mutations.** È il pattern dei commenti delle Clips
-- (clip_add_comment, clip_toggle_reaction): l'interazione ha regole che un upsert non sa dire —
-- il gate di visibilità dell'attività, i blocchi nei due versi, il parent che deve stare nello
-- stesso thread. Un ramo in apply_mutations accetterebbe la riga e basta; qui il rifiuto ha un
-- motivo e un errcode. Gli id restano client-generated per l'idempotenza offline: il retry dello
-- stesso gesto è la stessa riga.
--
-- **Un solo gate per tutti i verbi.** `activity_interaction_gate` è il cancello del feed
-- (autore pubblico+consenziente o se stessi) più i blocchi. Risponde `activity_not_available`
-- sia per "non esiste" sia per "bloccato": la stessa lezione di retry_import_job — la risposta
-- non deve essere un oracolo su chi ha bloccato chi.

create table if not exists public.activity_likes (
  id           uuid primary key,
  activity_id  uuid not null references public.activities (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  created_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  synced_at    timestamptz,
  unique (activity_id, user_id)
);

comment on table public.activity_likes is
  'Social feed M2: like sulle card. Id client-generated (retry idempotente); il toggle e'' una '
  'lapide che rivive, mai due righe per (attivita'', utente). Si scrive solo via toggle_activity_like.';

create index if not exists activity_likes_by_activity
  on public.activity_likes (activity_id) where deleted_at is null;

create table if not exists public.activity_comments (
  id           uuid primary key,
  activity_id  uuid not null references public.activities (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  parent_id    uuid references public.activity_comments (id) on delete set null,
  content      text not null check (char_length(btrim(content)) between 1 and 1000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  synced_at    timestamptz
);

comment on table public.activity_comments is
  'Social feed M2: commenti sulle card, un livello di reply (parent_id). Id client-generated. '
  'Si scrive solo via add/delete_activity_comment; legge get_activity_comments (gate + blocchi + report).';

create index if not exists activity_comments_by_activity
  on public.activity_comments (activity_id, created_at) where deleted_at is null;

create table if not exists public.activity_comment_likes (
  id          uuid primary key,
  comment_id  uuid not null references public.activity_comments (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  synced_at   timestamptz,
  unique (comment_id, user_id)
);

create index if not exists activity_comment_likes_by_comment
  on public.activity_comment_likes (comment_id) where deleted_at is null;

-- RLS accesa e select owner-only per coerenza con activities; ma il client non ha NESSUN verbo
-- diretto: tutte le strade passano dalle funzioni qui sotto.
alter table public.activity_likes enable row level security;
alter table public.activity_comments enable row level security;
alter table public.activity_comment_likes enable row level security;

drop policy if exists activity_likes_select_own on public.activity_likes;
create policy activity_likes_select_own on public.activity_likes
  for select using ((select auth.uid()) = user_id);
drop policy if exists activity_comments_select_own on public.activity_comments;
create policy activity_comments_select_own on public.activity_comments
  for select using ((select auth.uid()) = user_id);
drop policy if exists activity_comment_likes_select_own on public.activity_comment_likes;
create policy activity_comment_likes_select_own on public.activity_comment_likes
  for select using ((select auth.uid()) = user_id);

revoke all on public.activity_likes from public;
revoke all on public.activity_likes from anon;
revoke all on public.activity_likes from authenticated;
revoke all on public.activity_comments from public;
revoke all on public.activity_comments from anon;
revoke all on public.activity_comments from authenticated;
revoke all on public.activity_comment_likes from public;
revoke all on public.activity_comment_likes from anon;
revoke all on public.activity_comment_likes from authenticated;

-- --------------------------------------------------------------------------------- il gate
create or replace function public.activity_interaction_gate(p_activity_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  select a.user_id into v_owner
    from public.activities a
    join public.profiles p on p.id = a.user_id
   where a.id = p_activity_id
     and a.deleted_at is null
     and (a.user_id = v_uid
          or (p.deleted_at is null
              and p.username is not null
              and p.is_profile_public
              and p.activity_feed_enabled
              and p.feed_activated_at is not null));

  if v_owner is null then
    raise exception 'activity_not_available' using errcode = 'P0002';
  end if;

  if v_owner <> v_uid and exists (
       select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = v_uid and b.blocked_user_id = v_owner)
            or (b.user_id = v_owner and b.blocked_user_id = v_uid))
     ) then
    -- Stessa risposta dell'inesistente: il blocco non si annuncia.
    raise exception 'activity_not_available' using errcode = 'P0002';
  end if;

  return v_owner;
end $$;

-- --------------------------------------------------------------------------------- il like
--
-- Toggle: la riga per (attivita'', utente) e'' una sola, il like tolto e'' una lapide, il
-- re-like la rianima. `p_like_id` conta solo alla prima insert — un retry con id diverso
-- converge comunque sulla riga esistente.
create or replace function public.toggle_activity_like(
  p_activity_id uuid, p_like_id uuid default null)
returns table(liked boolean, like_count integer)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_existing uuid;
  v_dead    timestamptz;
begin
  perform public.activity_interaction_gate(p_activity_id);

  select l.id, l.deleted_at into v_existing, v_dead
    from public.activity_likes l
   where l.activity_id = p_activity_id and l.user_id = v_uid;

  if v_existing is null then
    insert into public.activity_likes (id, activity_id, user_id, synced_at)
    values (coalesce(p_like_id, gen_random_uuid()), p_activity_id, v_uid, now());
    liked := true;
  elsif v_dead is null then
    update public.activity_likes set deleted_at = now(), synced_at = now()
     where id = v_existing;
    liked := false;
  else
    update public.activity_likes set deleted_at = null, synced_at = now()
     where id = v_existing;
    liked := true;
  end if;

  select count(*)::int into like_count
    from public.activity_likes l
   where l.activity_id = p_activity_id and l.deleted_at is null;

  return next;
end $$;

-- ------------------------------------------------------------------------------ i commenti
create or replace function public.add_activity_comment(
  p_activity_id uuid, p_content text,
  p_comment_id uuid default null, p_parent_id uuid default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid := coalesce(p_comment_id, gen_random_uuid());
begin
  perform public.activity_interaction_gate(p_activity_id);

  if char_length(btrim(coalesce(p_content, ''))) not between 1 and 1000 then
    raise exception 'invalid_content' using errcode = '23514';
  end if;

  -- Il parent deve stare nello stesso thread ed essere vivo: una reply a un commento di
  -- un''altra attivita'' e'' un dato con cui nessuno puo'' fare qualcosa.
  if p_parent_id is not null and not exists (
       select 1 from public.activity_comments c
        where c.id = p_parent_id and c.activity_id = p_activity_id and c.deleted_at is null
     ) then
    raise exception 'parent_not_available' using errcode = 'P0002';
  end if;

  insert into public.activity_comments as t
    (id, activity_id, user_id, parent_id, content, synced_at)
  values
    (v_id, p_activity_id, v_uid, p_parent_id, btrim(p_content), now())
  on conflict (id) do update set
    content = excluded.content,
    updated_at = now(),
    synced_at = now()
  where t.user_id = v_uid;

  return v_id;
end $$;

-- Cancella il proprio commento, oppure — moderazione della propria card — un commento
-- qualunque sotto una propria attivita'': come su ogni social, casa propria, regole proprie.
create or replace function public.delete_activity_comment(p_comment_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  update public.activity_comments c
     set deleted_at = now(), synced_at = now()
   where c.id = p_comment_id
     and c.deleted_at is null
     and (c.user_id = v_uid
          or exists (select 1 from public.activities a
                      where a.id = c.activity_id and a.user_id = v_uid));

  if not found then
    raise exception 'comment_not_available' using errcode = 'P0002';
  end if;
end $$;

create or replace function public.toggle_activity_comment_like(
  p_comment_id uuid, p_like_id uuid default null)
returns table(liked boolean, like_count integer)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_activity uuid;
  v_author   uuid;
  v_existing uuid;
  v_dead     timestamptz;
begin
  select c.activity_id, c.user_id into v_activity, v_author
    from public.activity_comments c
   where c.id = p_comment_id and c.deleted_at is null;
  if v_activity is null then
    raise exception 'comment_not_available' using errcode = 'P0002';
  end if;

  perform public.activity_interaction_gate(v_activity);

  -- Il blocco vale anche verso l''autore del commento, non solo verso quello della card.
  if v_author <> v_uid and exists (
       select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = v_uid and b.blocked_user_id = v_author)
            or (b.user_id = v_author and b.blocked_user_id = v_uid))
     ) then
    raise exception 'comment_not_available' using errcode = 'P0002';
  end if;

  select l.id, l.deleted_at into v_existing, v_dead
    from public.activity_comment_likes l
   where l.comment_id = p_comment_id and l.user_id = v_uid;

  if v_existing is null then
    insert into public.activity_comment_likes (id, comment_id, user_id, synced_at)
    values (coalesce(p_like_id, gen_random_uuid()), p_comment_id, v_uid, now());
    liked := true;
  elsif v_dead is null then
    update public.activity_comment_likes set deleted_at = now(), synced_at = now()
     where id = v_existing;
    liked := false;
  else
    update public.activity_comment_likes set deleted_at = null, synced_at = now()
     where id = v_existing;
    liked := true;
  end if;

  select count(*)::int into like_count
    from public.activity_comment_likes l
   where l.comment_id = p_comment_id and l.deleted_at is null;

  return next;
end $$;

-- ------------------------------------------------------------------------------- la lettura
--
-- Ordine cronologico ASCENDENTE (un thread si legge dall'inizio) con cursore in avanti.
-- Un commento cancellato che ha reply vive resta come lapide (is_deleted, content null):
-- toglierlo orfanerebbe il filo. Senza reply vive, sparisce e basta.
create or replace function public.get_activity_comments(
  p_activity_id uuid,
  p_limit integer default 50,
  p_after timestamptz default null,
  p_after_id uuid default null)
returns table(
  comment_id uuid,
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  parent_id uuid,
  content text,
  is_deleted boolean,
  created_at timestamptz,
  like_count integer,
  liked_by_me boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.activity_interaction_gate(p_activity_id);

  return query
  select
    c.id as comment_id,
    c.user_id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    c.parent_id,
    case when c.deleted_at is not null then null else c.content end as content,
    (c.deleted_at is not null) as is_deleted,
    c.created_at,
    (select count(*)::int from public.activity_comment_likes l
      where l.comment_id = c.id and l.deleted_at is null) as like_count,
    exists(select 1 from public.activity_comment_likes l
            where l.comment_id = c.id and l.user_id = (select auth.uid())
              and l.deleted_at is null) as liked_by_me
  from public.activity_comments c
  join public.profiles p on p.id = c.user_id
  where c.activity_id = p_activity_id
    and (c.deleted_at is null
         or exists (select 1 from public.activity_comments r
                     where r.parent_id = c.id and r.deleted_at is null))
    -- Blocchi nei due versi anche sull''autore del commento, mai contro se stessi.
    and (
      c.user_id = (select auth.uid())
      or not exists (
        select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = (select auth.uid()) and b.blocked_user_id = c.user_id)
            or (b.user_id = c.user_id and b.blocked_user_id = (select auth.uid())))
      )
    )
    -- Stessa soglia delle liste: 3 segnalatori distinti nascondono, il proprietario vede.
    and (
      c.user_id = (select auth.uid())
      or (select count(distinct cr.reporter_id) from public.content_reports cr
           where cr.content_type = 'activity_comment' and cr.content_id = c.id) < 3
    )
    and (
      p_after is null
      or c.created_at > p_after
      or (c.created_at = p_after and p_after_id is not null and c.id > p_after_id)
    )
  order by c.created_at asc, c.id asc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end $$;

-- Grant: solo authenticated, il gate interno fa il resto. Tutti e tre i ruoli prima, fa fede proacl.
revoke all on function public.activity_interaction_gate(uuid) from public;
revoke all on function public.activity_interaction_gate(uuid) from anon;
revoke all on function public.activity_interaction_gate(uuid) from authenticated;

revoke all on function public.toggle_activity_like(uuid, uuid) from public;
revoke all on function public.toggle_activity_like(uuid, uuid) from anon;
revoke all on function public.toggle_activity_like(uuid, uuid) from authenticated;
grant execute on function public.toggle_activity_like(uuid, uuid) to authenticated;

revoke all on function public.add_activity_comment(uuid, text, uuid, uuid) from public;
revoke all on function public.add_activity_comment(uuid, text, uuid, uuid) from anon;
revoke all on function public.add_activity_comment(uuid, text, uuid, uuid) from authenticated;
grant execute on function public.add_activity_comment(uuid, text, uuid, uuid) to authenticated;

revoke all on function public.delete_activity_comment(uuid) from public;
revoke all on function public.delete_activity_comment(uuid) from anon;
revoke all on function public.delete_activity_comment(uuid) from authenticated;
grant execute on function public.delete_activity_comment(uuid) to authenticated;

revoke all on function public.toggle_activity_comment_like(uuid, uuid) from public;
revoke all on function public.toggle_activity_comment_like(uuid, uuid) from anon;
revoke all on function public.toggle_activity_comment_like(uuid, uuid) from authenticated;
grant execute on function public.toggle_activity_comment_like(uuid, uuid) to authenticated;

revoke all on function public.get_activity_comments(uuid, integer, timestamptz, uuid) from public;
revoke all on function public.get_activity_comments(uuid, integer, timestamptz, uuid) from anon;
revoke all on function public.get_activity_comments(uuid, integer, timestamptz, uuid) from authenticated;
grant execute on function public.get_activity_comments(uuid, integer, timestamptz, uuid) to authenticated;
