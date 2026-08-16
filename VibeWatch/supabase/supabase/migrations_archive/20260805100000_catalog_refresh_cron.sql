-- Il catalogo delle serie seguite si rinfresca da solo (Task 4 — "il tracking si aggiorna
-- quando escono nuovi episodi").
--
-- **Il difetto.** `tmdb_episodes` si popola quando qualcuno *chiede* una serie: al primo
-- caricamento del dettaglio, a un import, a un self-heal del client. Dopo, niente la tocca più.
-- Una serie chiusa ha `next_refresh_at` a 90 giorni; una serie "ended" che viene rinnovata non lo
-- ha proprio, perché nessuno la richiede più. Risultato: l'episodio nuovo esce, `tmdb_episodes`
-- non lo sa, `refresh_backlog_since()` ricalcola sugli stessi dati di ieri e la serie resta "in
-- pari" per sempre. L'utente lo scopre da un'altra app.
--
-- **La cura.** Un giro notturno che rinfresca il catalogo delle *sole serie seguite* — non tutto
-- TMDB — riusando `catalog-resolve` con `show_ids`, che quel lavoro lo sa già fare. Alle 04:00
-- UTC: dopo `catalog-prewarm` (03:30) e prima di `refresh-backlog` (05:00), così quando il
-- ricalcolo parte i dati nuovi ci sono già.

-- 1) Chi va rinfrescato, in ordine di urgenza.
--
-- Due sorgenti, unite: le serie seguite di cui non abbiamo proprio il catalogo (un self-heal che
-- oggi vive solo nel client, e quindi non succede mai se l'utente non apre la scheda), e quelle
-- il cui TTL è scaduto. La seconda condizione include un `refreshed_at` più vecchio di 30 giorni
-- a prescindere dal TTL: è il caso della serie "ended" rinnovata, che con un TTL a 90 giorni
-- resterebbe ferma per un trimestre.
create or replace function public.catalog_shows_needing_refresh(p_limit integer default 400)
returns table(tmdb_show_id integer)
language sql
stable
security definer
set search_path = public
as $$
  select x.tmdb_show_id from (
    -- 1) seguite senza catalogo (self-heal server-side, priorità massima)
    select st.tmdb_show_id, 0 as pri, now() - interval '100 years' as stale_since
      from public.tv_show_state st
      left join public.tmdb_shows s on s.tmdb_show_id = st.tmdb_show_id
     where st.user_status in ('active','for_later') and s.tmdb_show_id is null
    union
    -- 2) seguite con TTL scaduto, o "ended" ferme da >30gg (serie rinnovate dopo la chiusura)
    select st.tmdb_show_id, 1, s.refreshed_at
      from public.tv_show_state st
      join public.tmdb_shows s on s.tmdb_show_id = st.tmdb_show_id
     where st.user_status in ('active','for_later')
       and (s.next_refresh_at <= now() or s.refreshed_at < now() - interval '30 days')
  ) x
  group by x.tmdb_show_id, x.pri
  order by x.pri, min(x.stale_since)
  limit greatest(coalesce(p_limit, 400), 0);
$$;

-- 2) Il ricalcolo guarda anche le serie messe in pausa.
--
-- Stesso corpo della migration 20260730020000, con un solo cambiamento: `in ('active','for_later')`
-- al posto di `= 'active'`. Una serie snoozata non veniva mai ricalcolata, quindi chi la
-- riprendeva dopo mesi la trovava com'era il giorno dello snooze.
create or replace function public.refresh_backlog_since()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select s.user_id, s.tmdb_show_id
    from public.tv_show_state s
    where s.user_status in ('active', 'for_later')
      -- `current_date + 1` e non `current_date`: il job gira sull'orologio del server (UTC) ma il
      -- ricalcolo decide con `user_today`, che per un utente a UTC+14 e' gia' il giorno dopo.
      -- Senza il margine, chi vive a est vedrebbe l'episodio nuovo con 24 ore di ritardo.
      and (s.next_air_date is null or s.next_air_date <= current_date + 1)
  loop
    perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- 3) Chiusura verso l'API pubblica.
--
-- `catalog_shows_needing_refresh` è SECURITY DEFINER e legge `tv_show_state` di tutti: esposta
-- direbbe a chiunque quali serie segue la popolazione dell'app. Va revocata a PUBLIC (anon e
-- authenticated lo ereditano da lì) e concessa al solo `service_role`.
revoke execute on function public.catalog_shows_needing_refresh(integer) from public, anon, authenticated;
grant execute on function public.catalog_shows_needing_refresh(integer) to service_role;

-- 4) Il cron del rinfresco, alle 04:00 UTC.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'catalog-refresh') then
      perform cron.unschedule('catalog-refresh');
    end if;
    perform cron.schedule(
      'catalog-refresh',
      '0 4 * * *',
      $job$
      select net.http_post(
        url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/catalog-refresh',
        headers := jsonb_build_object(
          'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
          -- `catalog-refresh` controlla l'Authorization da sé: è l'unica cosa che distingue il
          -- rinfresco da una chiamata qualunque, e senza non parte.
          'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
          'Content-Type', 'application/json'),
        body := '{}'::jsonb);
      $job$
    );
  else
    raise notice 'pg_cron assente: schedulare catalog-refresh a mano (04:00 UTC)';
  end if;
end $$;

-- 5) `episode-radar` alle 05:30 UTC, dopo il ricalcolo.
--
-- La schedulazione non stava in nessuna migration: viveva solo nella dashboard, quindi un
-- ripristino del progetto la perdeva in silenzio. Alle 05:30 legge uno stato appena ricalcolato.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'episode-radar') then
      perform cron.unschedule('episode-radar');
    end if;
    perform cron.schedule(
      'episode-radar',
      '30 5 * * *',
      $job$
      select net.http_post(
        url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/episode-radar',
        headers := jsonb_build_object(
          'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
          'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
          'Content-Type', 'application/json'),
        body := '{}'::jsonb);
      $job$
    );
  else
    raise notice 'pg_cron assente: schedulare episode-radar a mano (05:30 UTC)';
  end if;
end $$;
