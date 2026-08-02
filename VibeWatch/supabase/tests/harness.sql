-- Impalcatura per far girare le migration su un Postgres vuoto.
--
-- Ricrea il minimo indispensabile di cio' che su Supabase esiste gia' ma la cui migration
-- PRECEDE questo repo (per anni l'intero albero supabase/ e' stato gitignorato, vedi il commento
-- in .gitignore). Non e' uno stub "per far passare i test": e' la parte di produzione che i test
-- devono poter presupporre.

-- Ruoli di Supabase. Servono ai grant per colonna e alle prove di RLS. `service_role` e'
-- arrivato con l'import (blocco §7.2): `import_apply_mutations` e' eseguibile solo da lui,
-- e i test devono poterlo impersonare per provarlo.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant select on tables to anon;

-- Lo schema in cui Supabase installa le estensioni. Qui non esiste di default.
create schema if not exists extensions;

-- `storage.objects`, ridotto alle sole colonne che `create_import_job` e
-- `imports_stale_uploads` consultano: esistenza/owner per la prima, `created_at` per il TTL
-- della seconda. In produzione lo schema e' di Supabase Storage; qui basta la forma. `owner`
-- (uuid, deprecato) e `owner_id` (text) esistono entrambi in produzione, e la funzione li
-- accetta entrambi — il test li prova uno per volta.
create schema if not exists storage;
create table if not exists storage.objects (
  bucket_id  text not null,
  name       text not null,
  owner      uuid,
  owner_id   text,
  created_at timestamptz not null default now()
);
grant usage on schema extensions to anon, authenticated;

-- Schema auth: solo cio' che le migration referenziano (FK su auth.users, auth.uid()).
create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text
);

-- Su Supabase legge il claim `sub` del JWT. Qui lo pilota il test con
-- `set local request.jwt.claim.sub = '<uuid>'`.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

-- In produzione Supabase concede USAGE su `auth` ai ruoli client, ed e' cio' che permette a una
-- funzione `security invoker` chiamata dal client (get_my_stats) di leggere auth.uid(). Le
-- policy RLS non lo richiedono (girano col proprietario della tabella), quindi la mancanza si
-- vede solo alla prima funzione invoker che tocca auth — meglio qui che in un FAIL criptico.
grant usage on schema auth to anon, authenticated, service_role;

-- Preferenze: la colonna count_specials_in_progress la aggiunge la migration di §1.3.
create table if not exists public.unified_user_preferences (
  user_id    uuid primary key references auth.users on delete cascade,
  updated_at timestamptz not null default now()
);

-- Il fuso dell'utente, gia' usato in produzione dalle quiet hours di process-notifications.
create table if not exists public.user_notification_preferences (
  user_id  uuid primary key references auth.users on delete cascade,
  timezone text
);

-- Le liste legacy, in forma minima: solo le colonne che `backfill_watchlist_tracking` legge
-- (migration della fusione ListsView-Tracking). Tipi verificati sulla produzione.
create table if not exists public.lists (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade,
  type       text not null,
  deleted_at timestamptz
);
create table if not exists public.list_items (
  id         uuid primary key default gen_random_uuid(),
  list_id    uuid not null references public.lists on delete cascade,
  user_id    uuid not null,
  media_id   integer,
  media_type text,
  added_at   timestamptz not null default now(),
  deleted_at timestamptz
);

-- Lo schema morto che la migration 20260730030000 deve rimuovere: senza queste, il drop
-- passerebbe per il solo fatto che non c'e' niente da droppare.
create table if not exists public.tv_tracking (
  user_id    uuid not null,
  tv_show_id integer not null,
  status     text,
  primary key (user_id, tv_show_id)
);
create table if not exists public.tv_episode_progress (
  user_id        uuid not null,
  tv_show_id     integer not null,
  season_number  integer not null,
  episode_number integer not null,
  primary key (user_id, tv_show_id, season_number, episode_number)
);
create or replace view public.v_tv_tracking_buckets as
  select user_id, tv_show_id, 'Continuing'::text as bucket from public.tv_tracking;
create or replace function public.get_tv_tracking_buckets()
returns setof public.v_tv_tracking_buckets
language sql stable security definer as $$ select * from public.v_tv_tracking_buckets; $$;

-- Asserzioni. Una fallita alza un'eccezione: con ON_ERROR_STOP il runner esce diverso da zero.
-- Accessibili anche da `authenticated`, perche' una parte dei test gira impersonando il client.
create schema if not exists t;
grant usage on schema t to anon, authenticated, service_role;
alter default privileges in schema t grant execute on functions to anon, authenticated, service_role;

create or replace function t.eq(actual anyelement, expected anyelement, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL  %  (atteso %, ottenuto %)', label, expected, actual;
  end if;
  raise notice 'ok    %', label;
end $$;

create or replace function t.is_true(actual boolean, label text)
returns void language plpgsql as $$
begin
  if actual is not true then
    raise exception 'FAIL  %  (atteso true, ottenuto %)', label, actual;
  end if;
  raise notice 'ok    %', label;
end $$;

/* Esegue uno statement e verifica che venga rifiutato. */
create or replace function t.rejects(statement text, label text)
returns void language plpgsql as $$
begin
  execute statement;
  raise exception 'FAIL  %  (lo statement e'' passato, doveva essere rifiutato)', label;
exception
  when raise_exception then raise;
  when others then raise notice 'ok    %  (% )', label, sqlstate;
end $$;

-- `profiles` come in produzione, con le sole colonne che il blocco 8 tocca. Ricreata qui perche'
-- la sua migration precede questo repo (per anni supabase/ e' stato gitignorato). Le colonne di
-- billing ci sono apposta: sono cio' che `public_profiles` non deve esporre, e un test che le
-- cerca deve poterle trovare nella tabella per dimostrare che nella vista non ci sono.
create table if not exists public.profiles (
  id           uuid primary key references auth.users on delete cascade,
  email        text not null,
  display_name text,
  avatar_url   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  synced_at    timestamptz,
  fcm_token    text,
  is_on_trial  boolean default false
);

alter table public.profiles enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select using ((select auth.uid()) = id);
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- `user_blocks` come in produzione (verificato su pg_policy il 2026-07-31): la sua migration
-- precede questo repo. La forma conta per due ragioni: `blocks_select_own` e' cio' che rende
-- necessario il `security definer` di `search_users` (il verso "mi ha bloccato" e' invisibile al
-- chiamante), e il trigger di `user_follows` la legge in scrittura. In produzione il default di
-- `id` e' uuid_generate_v4() (uuid-ossp); qui gen_random_uuid(), che e' builtin — cambia il
-- generatore, non il comportamento.
create table if not exists public.user_blocks (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users on delete cascade,
  blocked_user_id uuid not null references auth.users on delete cascade,
  created_at      timestamptz default now(),
  deleted_at      timestamptz,
  synced_at       timestamptz
);

alter table public.user_blocks enable row level security;

drop policy if exists blocks_select_own on public.user_blocks;
create policy blocks_select_own on public.user_blocks
  for select using ((select auth.uid()) = user_id);
drop policy if exists blocks_insert_own on public.user_blocks;
create policy blocks_insert_own on public.user_blocks
  for insert with check ((select auth.uid()) = user_id);
drop policy if exists blocks_update_own on public.user_blocks;
create policy blocks_update_own on public.user_blocks
  for update using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists blocks_delete_own on public.user_blocks;
create policy blocks_delete_own on public.user_blocks
  for delete using ((select auth.uid()) = user_id);
