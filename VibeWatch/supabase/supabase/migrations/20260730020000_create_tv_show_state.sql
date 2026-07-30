-- SPEC v3 §3.3 / §3.4 / §3.5 — Stato per serie, derivato e materializzato (blocco 3 di §12).
--
-- §1.1 `DECISO`: il progresso non si calcola piu' sul client. Oggi vive dentro TVTrackingCard.swift
-- come computed property di una View; sta per arrivare una web app, e due implementazioni della
-- stessa regola divergono sempre. Da qui in avanti l'autorevole e' il server e il client legge.
--
-- Non e' una materialized view: il refresh completo non scala per utente e non si puo' fare
-- incrementale. E' una tabella mantenuta da un trigger (§3.5) e da un job giornaliero.

-- 1) La preferenza di §1.3, unico interruttore per gli speciali nel progresso.
--    Guardata da to_regclass perche' la migration di unified_user_preferences precede il repo.
do $$
begin
  if to_regclass('public.unified_user_preferences') is not null then
    alter table public.unified_user_preferences
      add column if not exists count_specials_in_progress boolean not null default false;
  end if;
end $$;

create or replace function public.user_counts_specials(p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_value boolean;
begin
  select count_specials_in_progress into v_value
  from public.unified_user_preferences where user_id = p_user_id;
  return coalesce(v_value, false);
exception when others then
  -- Tabella o colonna assenti: il default di §1.3 e' "gli speciali non contano".
  return false;
end $$;

-- 2) "Oggi" per l'utente.
--
-- §3.3, limite noto: `tmdb_episodes.air_date` e' una `date`, senza ora ne' fuso di trasmissione,
-- quindi un episodio risulta disponibile dalla mezzanotte. La mitigazione accettata e' almeno
-- usare il fuso dell'utente invece di UTC secco. Il fuso e' quello che `process-notifications` usa
-- gia' per le quiet hours; se manca o e' invalido si ricade su UTC.
create or replace function public.user_today(p_user_id uuid)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_timezone text;
begin
  select nullif(timezone, '') into v_timezone
  from public.user_notification_preferences where user_id = p_user_id;
  return (now() at time zone coalesce(v_timezone, 'UTC'))::date;
exception when others then
  return (now() at time zone 'UTC')::date;
end $$;

-- 3) Lo stato.
create table if not exists public.tv_show_state (
  user_id            uuid not null references auth.users on delete cascade,
  tmdb_show_id       integer not null,

  -- Scelto dall'utente, non derivato: il ricalcolo non lo tocca mai.
  user_status        text not null default 'active'
                     check (user_status in ('active','for_later','dropped','archived')),

  -- Derivati dagli eventi + catalogo.
  watched_count      integer not null default 0,   -- episodi distinti non-speciali visti
  aired_count        integer not null default 0,   -- episodi non-speciali gia' usciti
  total_count        integer not null default 0,   -- episodi non-speciali totali (inclusi futuri)
  last_watched_at    timestamptz,

  -- Primo episodio non visto in ordine, ANCHE se non e' ancora uscito: serve alla timeline
  -- delle uscite (§9.2). Se sia gia' guardabile lo dice `is_next_available` nella vista.
  next_season        integer,
  next_episode       integer,
  next_air_date      date,

  -- Il cuore dell'ordinamento (§3.3).
  backlog_since      timestamptz,

  first_watched_at   timestamptz,
  completed_at       timestamptz,
  updated_at         timestamptz not null default now(),
  synced_at          timestamptz,

  primary key (user_id, tmdb_show_id)
);

-- L'ordinamento della schermata Tracking.
create index if not exists idx_tv_show_state_backlog
  on public.tv_show_state (user_id, backlog_since desc);
-- Il job giornaliero cerca le righe il cui prossimo episodio e' uscito nel frattempo.
create index if not exists idx_tv_show_state_next_air
  on public.tv_show_state (next_air_date) where user_status = 'active';

alter table public.tv_show_state enable row level security;

drop policy if exists tv_show_state_select on public.tv_show_state;
create policy tv_show_state_select on public.tv_show_state
  for select using ((select auth.uid()) = user_id);

-- L'utente puo' creare la riga (mettere una serie "da vedere piu' avanti" prima di averne visto
-- un episodio) e cambiarne lo stato. Non puo' toccare i derivati: quelli sono del server.
drop policy if exists tv_show_state_insert on public.tv_show_state;
create policy tv_show_state_insert on public.tv_show_state
  for insert with check ((select auth.uid()) = user_id);

drop policy if exists tv_show_state_update on public.tv_show_state;
create policy tv_show_state_update on public.tv_show_state
  for update using ((select auth.uid()) = user_id)
              with check ((select auth.uid()) = user_id);

-- La RLS dice QUALI righe; i grant per colonna dicono QUALI campi. Senza questi un client
-- potrebbe scriversi watched_count = 9999, che e' esattamente il dato che §1.1 sposta sul server.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke insert, update on public.tv_show_state from authenticated;
    grant insert (user_id, tmdb_show_id, user_status) on public.tv_show_state to authenticated;
    grant update (user_status) on public.tv_show_state to authenticated;
  end if;
end $$;

-- 4) Il ricalcolo.
--
-- backlog_since (§3.3):
--   next   = primo episodio non-speciale, gia' andato in onda, non visto, in ordine
--   backlog_since = null                                     se next non esiste (utente in pari)
--                 = greatest(next.air_date, last_watched_at)  altrimenti
--
-- E' `greatest` che soddisfa i due casi che il prodotto deve rispettare: una serie con un buco
-- vecchio NON risale quando esce una stagione nuova (vince last_watched_at, che e' vecchio),
-- mentre segnare visto l'ultimo episodio pendente fa risalire la serie subito.
create or replace function public.recompute_tv_show_state(p_user_id uuid, p_tmdb_show_id integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := public.user_today(p_user_id);
  v_specials boolean := public.user_counts_specials(p_user_id);
begin
  with watched as (
    select distinct e.season_number, e.episode_number
    from public.watch_events e
    where e.user_id = p_user_id
      and e.tmdb_show_id = p_tmdb_show_id
      and e.deleted_at is null
      and (v_specials or not public.is_special_episode(e.season_number))
  ),
  event_stats as (
    select min(e.watched_at) as first_watched_at, max(e.watched_at) as last_watched_at
    from public.watch_events e
    where e.user_id = p_user_id
      and e.tmdb_show_id = p_tmdb_show_id
      and e.deleted_at is null
      and (v_specials or not public.is_special_episode(e.season_number))
  ),
  catalog as (
    select c.season_number, c.episode_number, c.air_date
    from public.tmdb_episodes c
    where c.tmdb_show_id = p_tmdb_show_id
      and (v_specials or not public.is_special_episode(c.season_number))
  ),
  unwatched as (
    select c.* from catalog c
    where not exists (
      select 1 from watched w
      where w.season_number = c.season_number and w.episode_number = c.episode_number
    )
  ),
  next_any as (      -- anche non ancora uscito: alimenta la timeline
    select * from unwatched order by season_number, episode_number limit 1
  ),
  next_aired as (    -- solo gia' uscito: alimenta backlog_since
    select * from unwatched
    where air_date is not null and air_date <= v_today
    order by season_number, episode_number limit 1
  ),
  counts as (
    select
      -- Gli eventi sono la verita' su cosa l'utente ha visto: si contano anche gli episodi che il
      -- catalogo non conosce (numerazioni divergenti, l'oracolo ne documenta 31 casi su 430).
      (select count(*) from watched)::integer as watched_count,
      (select count(*) from catalog where air_date is not null and air_date <= v_today)::integer as aired_count,
      (select count(*) from catalog)::integer as total_count
  )
  insert into public.tv_show_state as s (
    user_id, tmdb_show_id,
    watched_count, aired_count, total_count,
    last_watched_at, first_watched_at,
    next_season, next_episode, next_air_date,
    backlog_since, completed_at, updated_at
  )
  select
    p_user_id, p_tmdb_show_id,
    c.watched_count, c.aired_count, c.total_count,
    es.last_watched_at, es.first_watched_at,
    na.season_number, na.episode_number, na.air_date,
    case
      when nx.season_number is null then null
      else greatest(nx.air_date::timestamp at time zone 'UTC', es.last_watched_at)
    end,
    case
      when c.total_count > 0 and c.watched_count >= c.total_count then now()
      else null
    end,
    now()
  from counts c
  cross join event_stats es
  left join next_any na on true
  left join next_aired nx on true
  on conflict (user_id, tmdb_show_id) do update set
    watched_count    = excluded.watched_count,
    aired_count      = excluded.aired_count,
    total_count      = excluded.total_count,
    last_watched_at  = excluded.last_watched_at,
    first_watched_at = excluded.first_watched_at,
    next_season      = excluded.next_season,
    next_episode     = excluded.next_episode,
    next_air_date    = excluded.next_air_date,
    backlog_since    = excluded.backlog_since,
    -- La data in cui e' stata finita si conserva: rifinirla non e' finirla di nuovo.
    completed_at     = case when excluded.completed_at is null then null
                            else coalesce(s.completed_at, excluded.completed_at) end,
    updated_at       = now();
    -- user_status resta quello dell'utente, di proposito.
end $$;

-- 5) Il trigger (§3.5).
--
-- A livello di STATEMENT con transition table, non per riga: l'import scrive 20.000 eventi su ~430
-- serie, e un trigger per riga farebbe 20.000 ricalcoli invece di 430. Il risultato e' identico,
-- il costo no.
--
-- Sull'UPDATE non si puo' usare `after update of deleted_at`: Postgres rifiuta una transition
-- table insieme a una lista di colonne ("transition tables cannot be specified for triggers with
-- column lists"). Il filtro si fa quindi dentro la funzione, confrontando le due transition table
-- — cosi' l'aggiornamento di `synced_at` che il sync fa a ogni push non ricalcola niente.
create or replace function public.tg_watch_events_recompute()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  if tg_op = 'INSERT' then
    for r in
      select distinct user_id, tmdb_show_id
      from changed_rows
      where tmdb_show_id is not null
    loop
      perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
    end loop;
  else
    for r in
      select distinct n.user_id, n.tmdb_show_id
      from changed_rows n
      join previous_rows o on o.id = n.id
      where n.tmdb_show_id is not null
        and n.deleted_at is distinct from o.deleted_at
    loop
      perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
    end loop;
  end if;
  return null;
end $$;

drop trigger if exists watch_events_recompute_insert on public.watch_events;
create trigger watch_events_recompute_insert
  after insert on public.watch_events
  referencing new table as changed_rows
  for each statement execute function public.tg_watch_events_recompute();

drop trigger if exists watch_events_recompute_delete on public.watch_events;
create trigger watch_events_recompute_delete
  after update on public.watch_events
  referencing old table as previous_rows new table as changed_rows
  for each statement execute function public.tg_watch_events_recompute();

-- 6) I bucket (§3.4).
create or replace function public.tv_tracking_bucket(
  p_user_status   text,
  p_watched_count integer,
  p_backlog_since timestamptz,
  p_stale_after   interval default interval '30 days'
)
returns text
language sql
stable
set search_path = public
as $$
  select case
    when p_user_status in ('dropped','archived') then p_user_status
    when p_user_status = 'for_later'             then 'for_later'
    when coalesce(p_watched_count, 0) = 0        then 'not_started'
    when p_backlog_since is null                 then 'up_to_date'
    when p_backlog_since >= now() - p_stale_after then 'up_next'
    else 'stale'
  end;
$$;

-- La vista che legge il client: lo stato piu' il bucket, piu' la risposta alla domanda che il
-- criterio di accettazione 3 pone ("un episodio non ancora uscito non compare mai come prossimo
-- da vedere"). Calcolarla qui una volta e' meglio che fidarsi che ogni client la rifaccia uguale.
--
-- security_invoker: la vista non aggira la RLS di tv_show_state, la eredita.
drop view if exists public.v_tv_tracking;
create view public.v_tv_tracking with (security_invoker = on) as
select
  s.*,
  public.tv_tracking_bucket(s.user_status, s.watched_count, s.backlog_since) as bucket,
  (s.next_air_date is not null and s.next_air_date <= public.user_today(s.user_id))
    as is_next_available
from public.tv_show_state s;

-- 7) Il job giornaliero (§3.5).
--
-- backlog_since cambia col passare del tempo anche senza azioni dell'utente: una serie in pari
-- torna in arretrato da sola quando esce l'episodio nuovo. Query mirata, non un refresh totale.
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
    where s.user_status = 'active'
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

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'refresh-backlog') then
      perform cron.unschedule('refresh-backlog');
    end if;
    perform cron.schedule('refresh-backlog', '0 5 * * *', 'select public.refresh_backlog_since()');
  else
    raise notice 'pg_cron assente: schedulare refresh_backlog_since() a mano (05:00 UTC)';
  end if;
end $$;

-- 8) Chiusura delle funzioni verso l'API pubblica.
--
-- Ogni funzione in `public` e' automaticamente un endpoint `/rest/v1/rpc/<nome>`. Queste sono
-- SECURITY DEFINER, quindi esposte sarebbero:
--
--   recompute_tv_show_state(user_id, show_id)  scrittura su tv_show_state per un user_id
--                                              ARBITRARIO, da parte di chiunque;
--   refresh_backlog_since()                    ricalcolo di OGNI riga attiva: una leva di DoS;
--   user_counts_specials(user_id)              la preferenza di un altro utente;
--   tg_watch_events_recompute()                funzione di trigger, senza senso fuori dal trigger.
--
-- Va revocato a PUBLIC, non ad anon/authenticated: Postgres concede EXECUTE a PUBLIC di default
-- e i due ruoli lo ereditano da li', quindi revocarlo solo a loro non toglie niente. (Verificato
-- in produzione con has_function_privilege: dopo il revoke mirato risultava ancora true.)
revoke execute on function public.recompute_tv_show_state(uuid, integer) from public, anon, authenticated;
revoke execute on function public.refresh_backlog_since()                 from public, anon, authenticated;
revoke execute on function public.user_counts_specials(uuid)              from public, anon, authenticated;
revoke execute on function public.tg_watch_events_recompute()             from public, anon, authenticated;
revoke execute on function public.user_today(uuid)                        from public, anon, authenticated;

-- `user_today` e' l'eccezione: `v_tv_tracking` e' security_invoker e la chiama per calcolare
-- `is_next_available`, quindi senza questo grant la schermata Tracking non leggerebbe piu'
-- niente. Espone una data, per un uuid che il chiamante deve gia' conoscere. Resta chiusa ad
-- anon; le altre, che scrivono o ricalcolano, restano chiuse a tutti.
grant execute on function public.user_today(uuid) to authenticated;
