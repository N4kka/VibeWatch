-- SPEC v3 §3.1 — Catalogo condiviso (blocco 2 di §12).
--
-- Oggi stagioni ed episodi non sono MAI persistiti: ogni card di tracking fa una chiamata TMDB
-- (N+2 per apertura della tab). Queste tre tabelle sono catalogo pubblico, non dato personale:
-- una riga sola per tutti gli utenti, lettura aperta, scrittura solo service_role via la Edge
-- Function `catalog-resolve` (§6).
--
-- Sbloccano insieme: lista up-next offline, timeline delle uscite, runtime reale per il watch
-- time, l'eliminazione delle N+2 chiamate, e l'import da TV Time (gli id nell'export sono
-- TheTVDB e vanno risolti una volta sola, per tutti).

-- 1) Serie: anagrafica minima.
create table if not exists public.tmdb_shows (
  tmdb_show_id       integer primary key,
  name               text not null,
  first_air_date     date,
  last_air_date      date,
  status             text,                    -- Returning Series / Ended / Canceled / In Production
  in_production      boolean,
  number_of_seasons  integer,
  number_of_episodes integer,
  poster_path        text,
  origin_country     text[],
  episode_run_time   integer[],
  refreshed_at       timestamptz not null default now(),
  -- TTL differenziato: una serie conclusa non cambia piu', una in onda si', e chi decide di
  -- quanto e' `catalog-resolve` (vedi nextRefreshAt in resolution.ts). Il default vale solo
  -- per una riga inserita senza passare di li'.
  next_refresh_at    timestamptz not null default now() + interval '7 days'
);

-- Le serie da rinfrescare: la query del job di refresh e' `where next_refresh_at <= now()`.
create index if not exists idx_tmdb_shows_next_refresh on public.tmdb_shows (next_refresh_at);

-- 2) Episodi: la tabella che oggi non esiste e che sblocca tutto.
create table if not exists public.tmdb_episodes (
  tmdb_show_id    integer not null references public.tmdb_shows on delete cascade,
  season_number   integer not null,
  episode_number  integer not null,
  tmdb_episode_id integer,
  name            text,
  air_date        date,
  runtime_minutes integer,
  still_path      text,
  refreshed_at    timestamptz not null default now(),
  primary key (tmdb_show_id, season_number, episode_number)
);

-- Timeline delle uscite: si interroga per data, e gli episodi senza air_date non ci finiscono mai.
create index if not exists idx_tmdb_episodes_air_date
  on public.tmdb_episodes (air_date) where air_date is not null;
create index if not exists idx_tmdb_episodes_show_season
  on public.tmdb_episodes (tmdb_show_id, season_number);

-- 3) Mappa TVDB -> TMDB, condivisa fra tutti gli utenti.
--
-- Gli id nell'export TV Time sono TheTVDB. Non aggiungiamo l'API TheTVDB: si risolve una volta e
-- si memorizza qui. Il primo utente che importa una serie paga la chiamata, tutti gli altri la
-- trovano gia' risolta.
create table if not exists public.tvdb_tmdb_map (
  tvdb_id        bigint not null,
  entity_type    text not null check (entity_type in ('series','episode','movie')),
  tmdb_show_id   integer,
  tmdb_movie_id  integer,
  season_number  integer,
  episode_number integer,
  resolution     text not null check (resolution in ('found','not_found','ambiguous')),
  method         text not null,            -- 'tmdb_find' | 'manual' | 'inherited_from_series'
  resolved_at    timestamptz not null default now(),
  primary key (tvdb_id, entity_type),

  -- Una riga 'found' che non punta a niente e' un bug dell'importer che altrimenti si scopre
  -- solo mesi dopo, come episodi mancanti nel diario di qualcuno.
  constraint tvdb_tmdb_map_found_points_somewhere check (
    resolution <> 'found' or tmdb_show_id is not null or tmdb_movie_id is not null
  ),
  -- Un episodio risolto senza stagione/episodio non e' risolto.
  constraint tvdb_tmdb_map_episode_shape check (
    resolution <> 'found' or entity_type <> 'episode'
    or (season_number is not null and episode_number is not null)
  )
);

-- §6.3: un 'not_found' non si ritenta per 30 giorni. La query di riprova filtra per
-- (resolution, resolved_at), non per chiave primaria.
create index if not exists idx_tvdb_tmdb_map_retry
  on public.tvdb_tmdb_map (resolution, resolved_at);

-- 4) RLS: lettura pubblica, scrittura solo service_role.
--
-- Nessuna policy di scrittura, di proposito: con RLS attiva e nessuna policy for insert/update,
-- un client autenticato non puo' scrivere. Solo service_role (che bypassa RLS) popola il
-- catalogo, cioe' `catalog-resolve`. Lasciarlo scrivere ai client sarebbe vandalismo gratuito su
-- dati condivisi da tutti.
alter table public.tmdb_shows    enable row level security;
alter table public.tmdb_episodes enable row level security;
alter table public.tvdb_tmdb_map enable row level security;

drop policy if exists tmdb_shows_select on public.tmdb_shows;
create policy tmdb_shows_select on public.tmdb_shows for select using (true);

drop policy if exists tmdb_episodes_select on public.tmdb_episodes;
create policy tmdb_episodes_select on public.tmdb_episodes for select using (true);

drop policy if exists tvdb_tmdb_map_select on public.tvdb_tmdb_map;
create policy tvdb_tmdb_map_select on public.tvdb_tmdb_map for select using (true);

-- 5) §1.3 — gli speciali si marcano, non si filtrano.
--
-- Oggi la stagione 0 e' esclusa da un `where` duplicato in due file del client. Questo e' il
-- punto di verita' unico: un episodio speciale resta tracciabile, ma non entra nel denominatore
-- del progresso ne' nel calcolo del prossimo episodio.
--
-- La preferenza utente `count_specials_in_progress` (§1.3) arriva col blocco 3, insieme al
-- calcolo del progresso che e' l'unico posto che la legge.
create or replace function public.is_special_episode(season_number integer)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  select coalesce(season_number, 0) = 0;
$$;

comment on function public.is_special_episode(integer) is
  'SPEC v3 §1.3: la stagione 0 e'' lo spazio degli speciali. Unico punto di verita'': nessun '
  'filtro sulla stagione 0 sparso nel client o nelle query.';
