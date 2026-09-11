-- Fusione ListsView ↔ Tracking — 2026-08-02, decisione di prodotto dell'utente.
--
-- Supera il confine di SPEC v3 §11 ("niente rifacimento di ListsView") per scelta esplicita:
-- ListsView è l'archivio di tutto ciò che l'utente aggiunge, e per le serie TV non duplica ma
-- LEGGE dal tracking (specchio `tv_tracking`); le scritture TV di ListsView/dettagli vanno al
-- tracking. Questa migration è il pezzo server, due cose:
--
--   1. `unsee_tv_show(p_tmdb_show_id)` — il contraltare di "vista tutta". Togliere una serie
--      dalla lista Seen ora significa mettere una lapide su TUTTI i suoi eventi e marcarla
--      `dropped`: senza il `dropped`, il ricalcolo la riporterebbe a `not_started` e la serie
--      "ricomparirebbe" in watchlist — l'opposto di ciò che l'utente ha chiesto facendo remove.
--      Un giro nell'outbox per evento non era una strada: sono centinaia di DELETE una a una
--      (una chiamata HTTP l'una), e `apply_mutations` le vuole per id che il client non ha.
--   2. `backfill_watchlist_tracking()` — il "pre-esistente" del verso ListsView → Tracking: le
--      serie TV già nelle watchlist legacy diventano righe `tv_show_state` attive ("Da
--      iniziare"). `on conflict do nothing`: uno stato già scelto (in app o dall'import TV Time)
--      non si tocca. È una funzione e non un DO block perché così l'harness la può collaudare
--      con dati veri e ri-eseguirla per provare l'idempotenza; la migration la chiama una volta.
--      (Il verso "seen legacy → eventi" NON sta qui: lo fa già `LegacyTrackingMigration` sul
--      client, che sa dialogare con catalog-resolve per le serie fuori catalogo.)

create or replace function public.unsee_tv_show(p_tmdb_show_id integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := (select auth.uid());
  v_removed integer;
begin
  -- Ancorata ad auth.uid() come apply_mutations: definer perche' authenticated non ha UPDATE su
  -- watch_events (il modello di scrittura e' la lapide via funzioni, mai la riga diretta).
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;
  if p_tmdb_show_id is null then
    raise exception 'p_tmdb_show_id is required' using errcode = '22023';
  end if;

  update public.watch_events
     set deleted_at = now(), synced_at = now()
   where user_id = v_uid
     and tmdb_show_id = p_tmdb_show_id
     and deleted_at is null;
  get diagnostics v_removed = row_count;

  insert into public.tv_show_state as t (user_id, tmdb_show_id, user_status, updated_at)
  values (v_uid, p_tmdb_show_id, 'dropped', now())
  on conflict (user_id, tmdb_show_id) do update set
    user_status = 'dropped',
    updated_at  = now();

  -- Il ricalcolo azzera i contatori ora che gli eventi hanno la lapide; user_status non lo
  -- tocca (verificato dal test "il ricalcolo non calpesta la scelta dell'utente").
  perform public.recompute_tv_show_state(v_uid, p_tmdb_show_id);

  return jsonb_build_object('events_removed', v_removed);
end
$$;

comment on function public.unsee_tv_show(integer) is
  'Fusione ListsView-Tracking: rimuovere una serie dalla lista Seen = lapide su tutti i suoi '
  'watch_events + user_status dropped (senza, il ricalcolo la farebbe ricomparire come '
  'not_started in watchlist). Ancorata ad auth.uid().';

revoke all on function public.unsee_tv_show(integer) from public, anon;
grant execute on function public.unsee_tv_show(integer) to authenticated;

create or replace function public.backfill_watchlist_tracking()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_inserted integer := 0;
begin
  for r in
    with ins as (
      insert into public.tv_show_state (user_id, tmdb_show_id, user_status, updated_at)
      select distinct li.user_id, li.media_id, 'active', now()
        from public.list_items li
        join public.lists l on l.id = li.list_id
        -- La join su auth.users e' una cintura: righe orfane di utenti cancellati non devono
        -- far fallire il backfill sulla FK di tv_show_state.
        join auth.users u on u.id = li.user_id
       where l.type = 'watchlist'
         and l.deleted_at is null
         and li.deleted_at is null
         and li.media_type = 'tv'
         and li.media_id > 0
      on conflict (user_id, tmdb_show_id) do nothing
      returning user_id, tmdb_show_id
    )
    select user_id, tmdb_show_id from ins
  loop
    v_inserted := v_inserted + 1;
    -- Le righe nascono a zero: il ricalcolo le allinea agli eventi che l'utente gia' ha (se una
    -- serie in watchlist aveva episodi visti, il bucket giusto non e' not_started).
    perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
  end loop;

  return jsonb_build_object('inserted', v_inserted);
end
$$;

comment on function public.backfill_watchlist_tracking() is
  'Fusione ListsView-Tracking: le serie TV nelle watchlist legacy diventano tv_show_state '
  'active ("Da iniziare"). Idempotente (on conflict do nothing): uno stato gia'' scelto non si '
  'tocca. Solo service: e'' un lavoro amministrativo, non un''azione utente.';

revoke all on function public.backfill_watchlist_tracking() from public, anon, authenticated;

-- Il backfill vero, una volta, adesso. Il NOTICE lascia il numero nei log della migration.
do $$
declare v jsonb;
begin
  v := public.backfill_watchlist_tracking();
  raise notice 'backfill_watchlist_tracking: %', v;
end $$;
