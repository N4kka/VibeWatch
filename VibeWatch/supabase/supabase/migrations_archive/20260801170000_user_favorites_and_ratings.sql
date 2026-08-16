-- SPEC v3 §3.6/§9.3 — blocco 9: `user_favorites` (4+4 slot) e `user_ratings` (mezze stelle).
--
-- Due aggiunte rispetto al DDL di §3.6, entrambe additive e con una ragione precisa:
--
-- **`deleted_at` su `user_favorites`.** Il DDL della spec non ce l'ha, ma la tabella sta nella
-- pull-list (§4) e il pull fa upsert per riga: una DELETE fisica sul server non arriva mai agli
-- altri dispositivi — lo slot svuotato resterebbe pieno su ogni mirror tranne quello che l'ha
-- svuotato. Ogni tabella utente sincronizzata di questo schema porta la lapide per lo stesso
-- motivo (`user_blocks`, `user_follows`, `movie_reactions`). Il DECISO di §3.6 sono i 4+4 slot
-- espliciti e l'ordine che conta: quello resta identico.
--
-- **CHECK di forma su `user_ratings`.** Stessa famiglia di `watch_events_shape`: un voto a un
-- episodio senza numero di episodio, o un film con una stagione, non è un dato con cui qualcuno
-- possa poi fare qualcosa. Il CHECK lo rifiuta alla nascita, dove il rifiuto è visibile, invece
-- di lasciarlo emergere in una stats che non torna.
--
-- **Perché `user_ratings` non ha un id sintetico.** Come `user_follows`: l'identità è la chiave
-- naturale (utente, media, eventuale episodio) e l'idempotenza della chiave è gratis. Un id
-- sintetico qui creerebbe il problema che altrove ha già morso: due dispositivi che votano lo
-- stesso film genererebbero id diversi per la stessa identità, e la riconciliazione andrebbe
-- reinventata. L'indice unico è parziale (`where deleted_at is null`) come da spec: una sola
-- riga viva per chiave; il re-voto dopo una cancellazione **riusa la riga** — ci pensa il ramo
-- in `apply_mutations`, che fa update-or-insert sulla chiave naturale, mai insert cieco.

-- ------------------------------------------------------------------------ user_favorites
create table if not exists public.user_favorites (
  user_id     uuid not null references auth.users (id) on delete cascade,
  media_type  text not null check (media_type in ('movie','tv')),
  slot        smallint not null check (slot between 1 and 4),
  tmdb_id     integer not null,
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  synced_at   timestamptz,
  primary key (user_id, media_type, slot)
);

comment on table public.user_favorites is
  'SPEC v3 §3.6: 4 slot film + 4 slot serie, separati; slot esplicito perche'' l''ordine conta. '
  'Sync: lastWriteWins (§4). Soft delete: uno slot svuotato e'' deleted_at, cosi'' il pull lo '
  'porta anche agli altri dispositivi.';

alter table public.user_favorites enable row level security;

-- Owner-only su tutti i verbi: i favorites di un profilo pubblico li mostra `get_public_profile`
-- (security definer), non un rilassamento della RLS — stessa scelta di `profiles`/`public_profiles`.
drop policy if exists favorites_select_own on public.user_favorites;
create policy favorites_select_own on public.user_favorites
  for select using ((select auth.uid()) = user_id);

drop policy if exists favorites_insert_own on public.user_favorites;
create policy favorites_insert_own on public.user_favorites
  for insert with check ((select auth.uid()) = user_id);

drop policy if exists favorites_update_own on public.user_favorites;
create policy favorites_update_own on public.user_favorites
  for update using ((select auth.uid()) = user_id)
             with check ((select auth.uid()) = user_id);

-- Anche `authenticated`, e poi il grant esatto: i default privileges danno DELETE alla
-- creazione, e il modello qui e' la lapide — una DELETE fisica dal client non deve esistere.
revoke all on public.user_favorites from public;
revoke all on public.user_favorites from anon;
revoke all on public.user_favorites from authenticated;
grant select, insert, update on public.user_favorites to authenticated;

-- -------------------------------------------------------------------------- user_ratings
create table if not exists public.user_ratings (
  user_id        uuid not null references auth.users (id) on delete cascade,
  media_type     text not null check (media_type in ('movie','tv','episode')),
  tmdb_id        integer not null,          -- show id se media_type='episode'
  season_number  integer,
  episode_number integer,
  rating         smallint not null check (rating between 1 and 10),  -- mezze stelle: 1..10 = 0.5..5.0
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  synced_at      timestamptz,

  constraint user_ratings_shape check (
    (media_type = 'episode' and season_number is not null and episode_number is not null)
    or
    (media_type in ('movie','tv') and season_number is null and episode_number is null)
  )
);

comment on table public.user_ratings is
  'SPEC v3 §3.6: voto in mezze stelle, intero 1-10 = 0.5-5.0 (scala Letterboxd), mai float. '
  'Coesiste con like/dislike: stelle = giudizio, cuore = "mi rappresenta". '
  'Sync: lastWriteWins (§4). Una riga viva per chiave (indice unico parziale); il re-voto dopo '
  'una cancellazione riusa la riga via apply_mutations.';

-- L'indice di §3.6, identico: unico sulla chiave naturale, solo sulle righe vive. Il primo
-- termine e' user_id, quindi copre anche il filtro del pull.
create unique index if not exists user_ratings_natural_key
  on public.user_ratings (user_id, media_type, tmdb_id,
                          coalesce(season_number, -1), coalesce(episode_number, -1))
  where deleted_at is null;

alter table public.user_ratings enable row level security;

drop policy if exists ratings_select_own on public.user_ratings;
create policy ratings_select_own on public.user_ratings
  for select using ((select auth.uid()) = user_id);

drop policy if exists ratings_insert_own on public.user_ratings;
create policy ratings_insert_own on public.user_ratings
  for insert with check ((select auth.uid()) = user_id);

drop policy if exists ratings_update_own on public.user_ratings;
create policy ratings_update_own on public.user_ratings
  for update using ((select auth.uid()) = user_id)
             with check ((select auth.uid()) = user_id);

revoke all on public.user_ratings from public;
revoke all on public.user_ratings from anon;
revoke all on public.user_ratings from authenticated;
grant select, insert, update on public.user_ratings to authenticated;
