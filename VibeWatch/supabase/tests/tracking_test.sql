-- Test dello stato di tracking (SPEC v3 §3.2-§3.5), sui criteri di accettazione di §13.
--
-- Si esegue con supabase/tests/run.sh, che crea un Postgres usa-e-getta, applica harness.sql e
-- tutte le migration, e poi questo file. Una asserzione fallita interrompe tutto.

\set ON_ERROR_STOP on
\set QUIET 1
\pset pager off
\pset tuples_only on
\pset footer off

begin;

-- Produzione gira in UTC, e senza questo il test dipenderebbe dal fuso di chi lo lancia:
-- `current_date` seguirebbe la sessione mentre `user_today()` calcola in UTC, e a mezzanotte
-- passata i due sarebbero giorni diversi.
set local timezone = 'UTC';

-- Due utenti: uno di prova e uno che non deve vedere niente dell'altro.
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test'),
  ('22222222-2222-2222-2222-222222222222', 'b@test');

-- Una serie di 10 episodi usciti + una seconda stagione: S2E1 uscito, S2E2 no.
insert into public.tmdb_shows (tmdb_show_id, name, status, in_production, number_of_seasons)
values (100, 'Test Show', 'Returning Series', true, 2);

insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date, runtime_minutes)
select 100, 1, n, current_date - 400, 45 from generate_series(1, 10) n;
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date, runtime_minutes)
values (100, 2, 1, current_date, 45),
       (100, 2, 2, current_date + 7, 45),
       (100, 0, 1, current_date - 500, 20);   -- uno speciale

\echo ''
\echo '=== §1.3 speciali'

select t.eq(public.is_special_episode(0), true,  'is_special_episode(0)');
select t.eq(public.is_special_episode(2), false, 'is_special_episode(2)');
select t.eq(public.is_special_episode(null), true, 'is_special_episode(null) tratta come speciale');

\echo ''
\echo '=== §3.5 il trigger mantiene lo stato'

-- 9 episodi su 10 visti, l'ultimo lasciato li' 6 mesi fa.
insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source)
select '11111111-1111-1111-1111-111111111111', 'tv', 100, 1, n,
       now() - interval '6 months', 'import_tvtime'
from generate_series(1, 9) n;

select t.eq((select count(*)::integer from public.tv_show_state
             where user_id = '11111111-1111-1111-1111-111111111111'), 1,
            'un insert di 9 righe produce la riga di stato');
select t.eq((select watched_count from public.tv_show_state where tmdb_show_id = 100), 9,
            'watched_count = 9');
select t.eq((select total_count from public.tv_show_state where tmdb_show_id = 100), 12,
            'total_count esclude lo speciale (12 = 10 + 2)');
select t.eq((select aired_count from public.tv_show_state where tmdb_show_id = 100), 11,
            'aired_count esclude lo speciale e il non ancora uscito');

\echo ''
\echo '=== §3.3 scenario 1: una serie con un buco vecchio NON risale (criterio 5)'

select t.eq((select next_season from public.tv_show_state where tmdb_show_id = 100), 1,
            'next resta S1E10, non salta alla stagione 2');
select t.eq((select next_episode from public.tv_show_state where tmdb_show_id = 100), 10,
            'next episode = 10');
select t.is_true((select backlog_since < now() - interval '5 months'
                  from public.tv_show_state where tmdb_show_id = 100),
            'backlog_since resta vecchio: greatest(air_date, last_watched) ~ 6 mesi fa');
select t.eq((select bucket from public.v_tv_tracking where tmdb_show_id = 100), 'stale',
            'bucket = stale, e ci resta anche se e'' uscita una stagione nuova');

\echo ''
\echo '=== §3.3 scenario 3: segnare visto l''ultimo pendente fa risalire subito (criterio 4)'

insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source)
values ('11111111-1111-1111-1111-111111111111', 'tv', 100, 1, 10, now(), 'manual');

select t.eq((select watched_count from public.tv_show_state where tmdb_show_id = 100), 10,
            'watched_count = 10');
select t.eq((select next_season from public.tv_show_state where tmdb_show_id = 100), 2,
            'next avanza a S2E1');
select t.eq((select next_episode from public.tv_show_state where tmdb_show_id = 100), 1,
            'next episode = 1');
select t.is_true((select backlog_since > now() - interval '1 minute'
                  from public.tv_show_state where tmdb_show_id = 100),
            'backlog_since risale a ora');
select t.eq((select bucket from public.v_tv_tracking where tmdb_show_id = 100), 'up_next',
            'bucket = up_next, in cima');

\echo ''
\echo '=== criterio 3: un episodio non ancora uscito non e'' mai il prossimo da vedere'

insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source)
values ('11111111-1111-1111-1111-111111111111', 'tv', 100, 2, 1, now(), 'manual');

select t.eq((select next_season from public.tv_show_state where tmdb_show_id = 100), 2,
            'next punta a S2E2, che esce fra una settimana (serve alla timeline)');
select t.eq((select next_episode from public.tv_show_state where tmdb_show_id = 100), 2,
            'next episode = 2');
select t.eq((select is_next_available from public.v_tv_tracking where tmdb_show_id = 100), false,
            'is_next_available = false finche'' non esce');
select t.eq((select backlog_since from public.tv_show_state where tmdb_show_id = 100), null,
            'backlog_since = null: l''utente e'' in pari');
select t.eq((select bucket from public.v_tv_tracking where tmdb_show_id = 100), 'up_to_date',
            'bucket = up_to_date');

\echo ''
\echo '=== §1.2 rewatch: una seconda visione non gonfia il progresso'

insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source, rewatch_index)
values ('11111111-1111-1111-1111-111111111111', 'tv', 100, 1, 1, now(), 'manual', 1);

select t.eq((select watched_count from public.tv_show_state where tmdb_show_id = 100), 11,
            'watched_count invariato sugli episodi distinti (10 + S2E1)');
select t.eq((select count(*)::integer from public.watch_events
             where tmdb_show_id = 100 and season_number = 1 and episode_number = 1), 2,
            'ma i due eventi restano entrambi: e'' un rewatch, non un duplicato');

\echo ''
\echo '=== §1.3 gli speciali entrano nel progresso solo se l''utente lo chiede'

insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source, is_special)
values ('11111111-1111-1111-1111-111111111111', 'tv', 100, 0, 1, now(), 'manual', true);

select t.eq((select watched_count from public.tv_show_state where tmdb_show_id = 100), 11,
            'lo speciale visto non entra nel progresso (default)');

insert into public.unified_user_preferences (user_id, count_specials_in_progress)
values ('11111111-1111-1111-1111-111111111111', true);
select public.recompute_tv_show_state('11111111-1111-1111-1111-111111111111', 100);

select t.eq((select watched_count from public.tv_show_state where tmdb_show_id = 100), 12,
            'con la preferenza attiva lo speciale conta');
select t.eq((select total_count from public.tv_show_state where tmdb_show_id = 100), 13,
            'e il denominatore include lo speciale');

update public.unified_user_preferences set count_specials_in_progress = false
where user_id = '11111111-1111-1111-1111-111111111111';
select public.recompute_tv_show_state('11111111-1111-1111-1111-111111111111', 100);

\echo ''
\echo '=== la cancellazione soft di un evento riporta indietro il progresso'

update public.watch_events set deleted_at = now()
where user_id = '11111111-1111-1111-1111-111111111111'
  and tmdb_show_id = 100 and season_number = 2 and episode_number = 1;

select t.eq((select watched_count from public.tv_show_state where tmdb_show_id = 100), 10,
            'watched_count torna a 10');
select t.eq((select next_season from public.tv_show_state where tmdb_show_id = 100), 2,
            'next torna a S2E1');
select t.eq((select next_episode from public.tv_show_state where tmdb_show_id = 100), 1,
            'next episode = 1');
select t.is_true((select backlog_since is not null from public.tv_show_state where tmdb_show_id = 100),
            'la serie torna in arretrato');

\echo ''
\echo '=== §3.4 bucket'

select t.eq(public.tv_tracking_bucket('active', 0, null), 'not_started', 'not_started');
select t.eq(public.tv_tracking_bucket('active', 5, null), 'up_to_date', 'up_to_date');
select t.eq(public.tv_tracking_bucket('active', 5, now() - interval '2 days'), 'up_next', 'up_next');
select t.eq(public.tv_tracking_bucket('active', 5, now() - interval '31 days'), 'stale', 'stale');
select t.eq(public.tv_tracking_bucket('for_later', 5, now()), 'for_later', 'for_later vince sul resto');
select t.eq(public.tv_tracking_bucket('dropped', 5, now()), 'dropped', 'dropped');
select t.eq(public.tv_tracking_bucket('archived', 5, now()), 'archived', 'archived');
select t.eq(public.tv_tracking_bucket('active', 5, now() - interval '31 days', interval '60 days'),
            'up_next', 'la soglia e'' configurabile');

\echo ''
\echo '=== §3.2 vincoli e idempotenza dell''import'

select t.rejects($$
  insert into public.watch_events (user_id, media_type, tmdb_show_id, watched_at)
  values ('11111111-1111-1111-1111-111111111111', 'tv', 100, now())
$$, 'un evento tv senza stagione/episodio e'' rifiutato');

select t.rejects($$
  insert into public.watch_events (user_id, media_type, tmdb_movie_id, tmdb_show_id, season_number, episode_number, watched_at)
  values ('11111111-1111-1111-1111-111111111111', 'movie', 603, 100, 1, 1, now())
$$, 'un evento film con campi da serie e'' rifiutato');

insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source, dedup_key)
values ('11111111-1111-1111-1111-111111111111', 'tv', 100, 1, 3, now(), 'import_tvtime', 'tvtime:999:0');

select t.rejects($$
  insert into public.watch_events
    (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source, dedup_key)
  values ('11111111-1111-1111-1111-111111111111', 'tv', 100, 1, 3, now(), 'import_tvtime', 'tvtime:999:0')
$$, 'criterio 2: lo stesso dedup_key non entra due volte');

-- Due utenti diversi possono avere lo stesso dedup_key: l'unicita' e' per utente.
insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source, dedup_key)
values ('22222222-2222-2222-2222-222222222222', 'tv', 100, 1, 3, now(), 'import_tvtime', 'tvtime:999:0');
select t.eq((select count(*)::integer from public.watch_events where dedup_key = 'tvtime:999:0'), 2,
            'il dedup e'' per utente, non globale');

\echo ''
\echo '=== §3.5 il job giornaliero'

-- Utente in pari su una serie il cui prossimo episodio esce domani.
insert into public.tmdb_shows (tmdb_show_id, name, status, in_production, number_of_seasons)
values (200, 'Airs Tomorrow', 'Returning Series', true, 1);
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date)
values (200, 1, 1, current_date - 30), (200, 1, 2, current_date + 1);
insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source)
values ('11111111-1111-1111-1111-111111111111', 'tv', 200, 1, 1, now() - interval '20 days', 'manual');

select t.eq((select backlog_since from public.tv_show_state where tmdb_show_id = 200), null,
            'in pari: nessun arretrato');

-- L'episodio esce.
update public.tmdb_episodes set air_date = current_date
where tmdb_show_id = 200 and season_number = 1 and episode_number = 2;

select t.is_true((select public.refresh_backlog_since() > 0), 'il job ricalcola qualcosa');
select t.is_true((select backlog_since is not null from public.tv_show_state where tmdb_show_id = 200),
            'la serie torna in arretrato da sola, senza che l''utente faccia niente');
select t.eq((select bucket from public.v_tv_tracking where tmdb_show_id = 200), 'up_next',
            'e risale in cima');

\echo ''
\echo '=== §1.2 lo schema morto e'' sparito'

select t.eq(to_regclass('public.tv_tracking')::text, null, 'tv_tracking droppata');
select t.eq(to_regclass('public.tv_episode_progress')::text, null, 'tv_episode_progress droppata');
select t.eq(to_regclass('public.v_tv_tracking_buckets')::text, null, 'v_tv_tracking_buckets droppata');
select t.eq((select count(*)::integer from pg_proc where proname = 'get_tv_tracking_buckets'), 0,
            'get_tv_tracking_buckets() droppata');

\echo ''
\echo '=== §1.1 il client non puo'' scrivere i derivati'

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select t.eq((select count(*)::integer from public.watch_events), 15,
            'l''utente vede solo i propri eventi, non quelli dell''altro');
select t.eq((select count(*)::integer from public.tv_show_state), 2,
            'e solo il proprio stato');

select t.rejects($$
  update public.tv_show_state set watched_count = 9999 where tmdb_show_id = 100
$$, 'un client non puo'' scriversi watched_count');

-- Le funzioni di ricalcolo non sono chiamabili via API: sono SECURITY DEFINER, e in `public`
-- ogni funzione e' automaticamente un endpoint /rest/v1/rpc/<nome>. Esposte, un anonimo potrebbe
-- far ricalcolare (e scrivere) lo stato di chiunque, o innescare refresh_backlog_since() in loop.
select t.eq(has_function_privilege('public.recompute_tv_show_state(uuid,integer)', 'execute'), false,
            'recompute non e'' chiamabile dal client');
select t.eq(has_function_privilege('public.refresh_backlog_since()', 'execute'), false,
            'refresh_backlog_since non e'' chiamabile dal client');
select t.eq(has_function_privilege('public.user_counts_specials(uuid)', 'execute'), false,
            'user_counts_specials non e'' chiamabile dal client');
-- Eccezione voluta: `v_tv_tracking` e' security_invoker e la chiama.
select t.eq(has_function_privilege('public.user_today(uuid)', 'execute'), true,
            'user_today resta chiamabile: senza, la vista non leggerebbe piu'' niente');

-- E il trigger deve scattare lo stesso. Postgres verifica l'EXECUTE quando si CREA il trigger,
-- non quando scatta: se questa assunzione fosse sbagliata, ogni "segna visto" dell'app
-- fallirebbe subito dopo l'hardening.
insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source)
values ('11111111-1111-1111-1111-111111111111', 'tv', 300, 1, 1, now(), 'manual');
select t.eq((select watched_count from public.tv_show_state where tmdb_show_id = 300), 1,
            'il trigger ricalcola anche se il client non puo'' chiamare le funzioni');

update public.tv_show_state set user_status = 'for_later' where tmdb_show_id = 100;
select t.eq((select user_status from public.tv_show_state where tmdb_show_id = 100), 'for_later',
            'ma puo'' cambiare user_status, che e'' una sua scelta');
select t.eq((select bucket from public.v_tv_tracking where tmdb_show_id = 100), 'for_later',
            'e il bucket lo segue');

reset role;

-- Il ricalcolo non calpesta la scelta dell'utente. Senza il ruolo `authenticated` la RLS non
-- filtra piu' niente, quindi qui la riga va scelta per utente: sulla serie 100 ce n'e' anche una
-- del secondo utente, creata dal test sul dedup.
select public.recompute_tv_show_state('11111111-1111-1111-1111-111111111111', 100);
select t.eq((select user_status from public.tv_show_state
             where tmdb_show_id = 100 and user_id = '11111111-1111-1111-1111-111111111111'),
            'for_later', 'il ricalcolo non tocca user_status');

\echo ''
\echo '=== §3.3 il fuso dell''utente'

insert into public.user_notification_preferences (user_id, timezone)
values ('11111111-1111-1111-1111-111111111111', 'Pacific/Kiritimati');
select t.is_true((select public.user_today('11111111-1111-1111-1111-111111111111')
                  >= (now() at time zone 'UTC')::date),
            'user_today segue il fuso dell''utente (UTC+14 non e'' mai indietro)');

update public.user_notification_preferences set timezone = 'Non/Existent'
where user_id = '11111111-1111-1111-1111-111111111111';
select t.eq(public.user_today('11111111-1111-1111-1111-111111111111'),
            (now() at time zone 'UTC')::date,
            'un fuso invalido ricade su UTC invece di far fallire il ricalcolo');

select t.eq(public.user_today('33333333-3333-3333-3333-333333333333'),
            (now() at time zone 'UTC')::date,
            'un utente senza preferenze usa UTC');

rollback;

\echo ''
\echo 'TUTTI I TEST PASSATI'
