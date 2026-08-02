-- SPEC v3 §3.2 — Eventi di visione (blocco 3 di §12).
--
-- Tabella di EVENTI, non di stato. `tv_episode_progress` ha PK (user, show, season, episode) e per
-- costruzione non puo' rappresentare un rewatch: l'utente lo vuole, e il solo export TV Time di
-- prova ne contiene 155 reali. Qui ogni visione e' una riga, e il progresso e' derivato (§3.3).
--
-- Il client scrive via outbox e applica un aggiornamento ottimistico locale; l'autorevole per lo
-- stato derivato resta il server (§1.1).

create table if not exists public.watch_events (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users on delete cascade,

  media_type       text not null check (media_type in ('movie','tv')),
  tmdb_movie_id    integer,                  -- valorizzato sse media_type='movie'
  tmdb_show_id     integer,                  -- valorizzato sse media_type='tv'
  season_number    integer,
  episode_number   integer,

  -- La distinzione che nessun altro importer conserva, ed e' il motivo per cui qualcuno
  -- sceglierebbe VibeWatch: quando l'utente ha VISTO qualcosa, non quando l'ha registrato.
  watched_at       timestamptz not null,
  logged_at        timestamptz not null default now(),
  watched_at_precision text not null default 'exact'
                   check (watched_at_precision in ('exact','date_only','inferred')),

  runtime_seconds  integer,                  -- snapshot al momento della visione
  is_special       boolean not null default false,
  rewatch_index    integer not null default 0 check (rewatch_index >= 0),  -- 0 = prima visione

  source           text not null default 'manual'
                   check (source in ('manual','bulk_season','bulk_show','import_tvtime','import_other')),
  external_ref     jsonb,                    -- {tvdb_episode_id, tvtime_reaction_id, tvtime_star_raw, ...}
  dedup_key        text,                     -- 'tvtime:{tvdb_episode_id}:{rewatch_index}'

  device_id        text,
  deleted_at       timestamptz,
  synced_at        timestamptz,

  constraint watch_events_shape check (
    (media_type = 'movie' and tmdb_movie_id is not null
        and tmdb_show_id is null and season_number is null and episode_number is null)
    or
    (media_type = 'tv' and tmdb_show_id is not null
        and season_number is not null and episode_number is not null)
  )
);

-- Idempotenza dell'import (criterio di accettazione 2): reimportare lo stesso ZIP non duplica.
-- Il tracking manuale lascia dedup_key null, perche' segnare due volte lo stesso episodio a mano
-- e' un rewatch intenzionale e deve poter passare.
create unique index if not exists watch_events_dedup on public.watch_events (user_id, dedup_key)
  where dedup_key is not null and deleted_at is null;

-- Il ricalcolo dello stato per serie legge esattamente per questa chiave.
create index if not exists watch_events_by_episode
  on public.watch_events (user_id, tmdb_show_id, season_number, episode_number)
  where deleted_at is null;

-- Il diario (§9.3) scorre in ordine cronologico inverso.
create index if not exists watch_events_by_watched_at
  on public.watch_events (user_id, watched_at desc)
  where deleted_at is null;

alter table public.watch_events enable row level security;

-- Dati personali: ogni policy e' scopata al proprietario. `(select auth.uid())` invece di
-- `auth.uid()` perche' Postgres lo valuta una volta sola per query invece che per riga.
drop policy if exists watch_events_select on public.watch_events;
create policy watch_events_select on public.watch_events
  for select using ((select auth.uid()) = user_id);

drop policy if exists watch_events_insert on public.watch_events;
create policy watch_events_insert on public.watch_events
  for insert with check ((select auth.uid()) = user_id);

drop policy if exists watch_events_update on public.watch_events;
create policy watch_events_update on public.watch_events
  for update using ((select auth.uid()) = user_id)
              with check ((select auth.uid()) = user_id);

-- Nessuna DELETE: si cancella con `deleted_at`, come tutto il resto del sync.
