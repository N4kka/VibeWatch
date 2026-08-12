-- STAB-011: il client scrive e sincronizza movie_reactions / movie_reaction_counts da sempre,
-- ma nessuna delle due tabelle esisteva su Supabase: ogni push falliva e il pull era stato
-- rimosso da SyncEngine per non far risultare fallito ogni sync.

-- 1) Reazioni per-utente. Chiave naturale (user_id, media_id, media_type), come in SQLite.
create table if not exists public.movie_reactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  media_id      integer not null,
  media_type    text not null check (media_type in ('movie','tv')),
  reaction_type text not null check (reaction_type in ('like','dislike')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  synced_at     timestamptz,
  unique (user_id, media_id, media_type)
);

create index if not exists idx_movie_reactions_user on public.movie_reactions(user_id);
create index if not exists idx_movie_reactions_media on public.movie_reactions(media_id, media_type);

alter table public.movie_reactions enable row level security;

-- SELECT scopata all'utente: like/dislike sui titoli sono dati di gusto personale.
-- (clip_reactions usa select true perche' quelle sono mostrate pubblicamente sotto la clip;
--  qui non c'e' nessuna UI pubblica e il client legge solo le proprie righe, via eq(user_id).)
create policy movie_reactions_select on public.movie_reactions
  for select using ((select auth.uid()) = user_id);
create policy movie_reactions_insert on public.movie_reactions
  for insert with check ((select auth.uid()) = user_id);
create policy movie_reactions_update on public.movie_reactions
  for update using ((select auth.uid()) = user_id)
              with check ((select auth.uid()) = user_id);
create policy movie_reactions_delete on public.movie_reactions
  for delete using ((select auth.uid()) = user_id);

-- 2) Aggregato pubblico. NON scrivibile dal client: e' un contatore globale, e lasciarlo
-- scrivere da chiunque sarebbe un vettore di vandalismo (like_count arbitrario su qualsiasi
-- titolo) per zero beneficio, dato che nessuno lo legge da Supabase. Lo mantiene un trigger.
create table if not exists public.movie_reaction_counts (
  media_id      integer not null,
  media_type    text not null check (media_type in ('movie','tv')),
  like_count    integer not null default 0,
  dislike_count integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (media_id, media_type)
);

alter table public.movie_reaction_counts enable row level security;

-- Sola lettura per i client; nessuna policy di scrittura => solo service_role puo' scrivere,
-- e in pratica scrive solo il trigger qui sotto (SECURITY DEFINER).
create policy movie_reaction_counts_select on public.movie_reaction_counts
  for select using (true);

create or replace function public.refresh_movie_reaction_counts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_media_id   integer;
  v_media_type text;
begin
  v_media_id   := coalesce(new.media_id, old.media_id);
  v_media_type := coalesce(new.media_type, old.media_type);

  insert into public.movie_reaction_counts (media_id, media_type, like_count, dislike_count, updated_at)
  select v_media_id,
         v_media_type,
         count(*) filter (where reaction_type = 'like'    and deleted_at is null),
         count(*) filter (where reaction_type = 'dislike' and deleted_at is null),
         now()
    from public.movie_reactions
   where media_id = v_media_id and media_type = v_media_type
  on conflict (media_id, media_type) do update
     set like_count    = excluded.like_count,
         dislike_count = excluded.dislike_count,
         updated_at    = excluded.updated_at;

  return null;
end;
$$;

create trigger trg_movie_reactions_counts
after insert or update or delete on public.movie_reactions
for each row execute function public.refresh_movie_reaction_counts();
