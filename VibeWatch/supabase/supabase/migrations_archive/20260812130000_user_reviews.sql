-- Social feed M1 — `user_reviews`: la one-liner alla Letterboxd.
--
-- **Perché una review e non un campo su `user_ratings`.** Rating e review sono atti diversi con
-- vite diverse: si vota senza scrivere, si scrive senza rivotare, e la review ha bisogni che il
-- rating non ha (i report la referenziano, lo spoiler flag, un limite di lunghezza). Fondere le
-- due cose nella chiave naturale di `user_ratings` — che un id sintetico non ce l'ha per scelta —
-- costringerebbe i report a inventarsi un'identità. Nel feed le due cose confluiscono comunque
-- nella stessa card: ci pensa `activities` (stessa `group_key`), non lo schema di scrittura.
--
-- **Perché l'id è sintetico e lo genera il client.** A differenza di `user_ratings`, qui serve
-- un'identità referenziabile: `content_reports` (M2) punta alla review, e `activities.review_id`
-- già da M1. Il client genera l'uuid come fa `ClipCommentService` per i commenti: l'upsert
-- offline resta idempotente — due retry dello stesso salvataggio sono la stessa riga, non due.
-- L'unicità per titolo la difende comunque l'indice parziale: una sola review viva per
-- (utente, media, titolo), il re-write dopo una cancellazione riusa la riga via `apply_mutations`.
--
-- **280 caratteri.** Non un vezzo: il formato corto è ciò che rende le review di Letterboxd un
-- genere leggibile in un feed. Il CHECK conta sul contenuto trimmato: 280 spazi non sono una review.

create table if not exists public.user_reviews (
  id                 uuid primary key,
  user_id            uuid not null references auth.users (id) on delete cascade,
  media_type         text not null check (media_type in ('movie','tv')),
  tmdb_id            integer not null,
  content            text not null check (char_length(btrim(content)) between 1 and 280),
  contains_spoilers  boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  synced_at          timestamptz
);

comment on table public.user_reviews is
  'Social feed M1: review breve (<=280 char) per titolo, stile Letterboxd. Una sola riga viva '
  'per (user, media_type, tmdb_id); id sintetico client-generated perche'' report e activities '
  'la referenziano. Sync: lastWriteWins. Soft delete: la lapide viaggia col pull.';

-- Una sola review viva per titolo; il primo termine e' user_id, quindi copre anche il pull.
create unique index if not exists user_reviews_one_per_title
  on public.user_reviews (user_id, media_type, tmdb_id)
  where deleted_at is null;

alter table public.user_reviews enable row level security;

-- Owner-only su tutti i verbi: le review altrui le mostra `get_activity_feed` (security definer,
-- con blocchi e report applicati), non un rilassamento della RLS — stessa scelta di
-- `user_favorites`/`user_ratings`.
drop policy if exists reviews_select_own on public.user_reviews;
create policy reviews_select_own on public.user_reviews
  for select using ((select auth.uid()) = user_id);

drop policy if exists reviews_insert_own on public.user_reviews;
create policy reviews_insert_own on public.user_reviews
  for insert with check ((select auth.uid()) = user_id);

drop policy if exists reviews_update_own on public.user_reviews;
create policy reviews_update_own on public.user_reviews
  for update using ((select auth.uid()) = user_id)
             with check ((select auth.uid()) = user_id);

-- Anche `authenticated`, e poi il grant esatto: i default privileges danno DELETE alla creazione,
-- e il modello qui e' la lapide — una DELETE fisica dal client non deve esistere.
revoke all on public.user_reviews from public;
revoke all on public.user_reviews from anon;
revoke all on public.user_reviews from authenticated;
grant select, insert, update on public.user_reviews to authenticated;
