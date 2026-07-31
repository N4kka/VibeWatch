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

\echo ''
\echo '=== §7.4 il report di fine import'

-- Un job finto con la forma vera dello staging: due episodi scritti, uno non riconosciuto,
-- due voti (uno indecodificabile). Serve a verificare che il report NON abbellisca.
insert into public.import_jobs (id, user_id, source, status, phase, totals)
values ('aaaaaaaa-0000-4000-8000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'tvtime', 'running', 'recomputing',
        '{"written": 2}'::jsonb);

insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 0,
   '{"row_kind":"event","series_name":"Test Show","tvdb_series_id":"900","watched_at":"2019-07-02 05:58:55"}'::jsonb,
   '{"tmdb_show_id":100,"season_number":1,"episode_number":1}'::jsonb, 'written', null),
  ('aaaaaaaa-0000-4000-8000-000000000001', 1,
   '{"row_kind":"event","series_name":"Test Show","tvdb_series_id":"900","watched_at":"2021-03-04 10:00:00"}'::jsonb,
   '{"tmdb_show_id":100,"season_number":1,"episode_number":2}'::jsonb, 'written', null),
  ('aaaaaaaa-0000-4000-8000-000000000001', 2,
   '{"row_kind":"event","series_name":"Serie Sconosciuta","tvdb_series_id":"901","watched_at":"2020-01-01 00:00:00"}'::jsonb,
   null, 'unresolved', 'catalogo: not_found'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 3,
   '{"row_kind":"rating","kind":"star"}'::jsonb, null, 'skipped', 'voti rinviati'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 4,
   '{"row_kind":"rating","kind":"undecodable"}'::jsonb, null, 'skipped', 'voti rinviati');

select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'episodi_importati')::int,
            2, 'il report conta gli episodi davvero scritti');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'serie_importate')::int,
            1, 'e le serie distinte');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'dal',
            '2019-07-02 05:58:55', 'intervallo di date: dal');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'al',
            '2021-03-04 10:00:00', 'intervallo di date: al');

-- Il cuore di §7.4: i non riconosciuti non sono un numero, sono un elenco di titoli.
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'non_riconosciuti_episodi')::int,
            1, 'un episodio non riconosciuto viene dichiarato');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'non_riconosciuti_elenco'->0->>'titolo',
            'Serie Sconosciuta', 'il report nomina il titolo, non solo il conteggio');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'non_riconosciuti_elenco'->0->>'motivo',
            'catalogo: not_found', 'e dice perche'', cosi'' si puo'' risolvere a mano');

select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'voti_indecodificabili')::int,
            1, 'i voti indecodificabili si dichiarano (§7.5)');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'voti_importati',
            'false', 'e si dice che i voti NON sono stati importati: user_ratings arriva col blocco 9');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'film_supportati',
            'false', 'zero film non deve sembrare "non ne avevi": i film non si importano ancora');


-- La fase 5 deve vedere TUTTE le serie toccate, a blocchi, senza saltarne.
select t.eq((select count(*) from public.import_touched_shows(
              'aaaaaaaa-0000-4000-8000-000000000001', 0, 200)),
            1::bigint, 'le serie toccate dal job sono quelle scritte, distinte');
select t.eq((select count(*) from public.import_touched_shows(
              'aaaaaaaa-0000-4000-8000-000000000001', 100, 200)),
            0::bigint, 'il checkpoint per id di serie non rilegge cio'' che ha gia'' fatto');

-- Un import che perde tutto non deve poter sembrare riuscito.
insert into public.import_jobs (id, user_id, source, status, phase)
values ('aaaaaaaa-0000-4000-8000-000000000002',
        '11111111-1111-1111-1111-111111111111', 'tvtime', 'running', 'recomputing');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000002')->>'episodi_importati')::int,
            0, 'un job senza righe dichiara zero episodi');

-- Zero non e' null. Il coalesce dentro la sottoquery non veniva mai eseguito quando la sottoquery
-- non trovava righe, e il report diceva "voti_stelle: null" invece di 0 — visto in produzione.
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000002')->>'voti_stelle')::int,
            0, 'nessun voto in stelle si dichiara come 0, non come null');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000002')->>'voti_reaction')::int,
            0, 'idem per le reaction');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000002')->>'voti_indecodificabili')::int,
            0, 'idem per gli indecodificabili');
select t.is_true((public.import_report('aaaaaaaa-0000-4000-8000-000000000002')->'voti_stelle')
                 <> 'null'::jsonb,
            'il campo non e'' il json null, che il client mostrerebbe come vuoto');

\echo ''
\echo '=== §9.2 le viste della schermata Tracking'

-- La card ha bisogno del catalogo: senza, resterebbe senza titolo e senza poster.
select t.eq((select show_name from public.v_tv_tracking
              where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 100),
            'Test Show', 'la vista porta il nome della serie, non solo i contatori');

-- Il nome dell'episodio e' quello del PROSSIMO, agganciato per (stagione, episodio). Si nomina
-- l'episodio che lo stato indica come prossimo invece di assumere quale sia: assumerlo rendeva il
-- test dipendente dall'ordine delle asserzioni sopra, ed e' cosi' che e' fallito la prima volta.
select t.is_true((select next_season is not null and next_episode is not null
                    from public.tv_show_state
                   where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 100),
            'precondizione: la serie ha un prossimo episodio da mostrare');

update public.tmdb_episodes e set name = 'Il prossimo'
  from public.tv_show_state s
 where s.user_id = '11111111-1111-1111-1111-111111111111'
   and s.tmdb_show_id = 100
   and e.tmdb_show_id = s.tmdb_show_id
   and e.season_number = s.next_season
   and e.episode_number = s.next_episode;

select t.eq((select next_episode_name from public.v_tv_tracking
              where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 100),
            'Il prossimo', 'e il titolo del prossimo episodio, agganciato per S/E');

-- §13.6: una serie tracciata senza catalogo risolto deve restare nella lista, non sparire.
insert into public.tv_show_state (user_id, tmdb_show_id, user_status, watched_count)
values ('11111111-1111-1111-1111-111111111111', 999999, 'active', 3);
select t.eq((select count(*) from public.v_tv_tracking
              where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 999999),
            1::bigint, 'una serie senza catalogo compare lo stesso (LEFT JOIN, non INNER)');
select t.is_true((select show_name is null from public.v_tv_tracking
                   where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 999999),
            'col nome vuoto, che la UI puo'' gestire');

-- Timeline. Il blocco si porta il proprio stato invece di ereditare quello dei test sopra:
-- assumerlo e' gia' costato due asserzioni sbagliate in questo stesso file.
update public.tv_show_state set user_status = 'active'
 where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 100;

-- Confronto con un conteggio calcolato a parte, non con un numero scritto a mano: se domani
-- cambiano gli episodi di prova, il test resta vero senza doverlo riscrivere.
select t.eq((select count(*) from public.v_tv_timeline
              where user_id = '11111111-1111-1111-1111-111111111111'),
            (select count(*)
               from public.tmdb_episodes e
              where e.air_date between current_date and current_date + 30
                and exists (select 1 from public.tv_show_state st
                             where st.user_id = '11111111-1111-1111-1111-111111111111'
                               and st.tmdb_show_id = e.tmdb_show_id
                               and st.user_status = 'active')),
            'la timeline e'' esattamente cio'' che esce da oggi a +30 giorni');
select t.is_true((select coalesce(bool_and(air_date >= current_date), true)
                    from public.v_tv_timeline
                   where user_id = '11111111-1111-1111-1111-111111111111'),
            'e nessuna uscita e'' nel passato');

-- §1.3: uno speciale futuro compare ed e' MARCATO, non filtrato.
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date, name)
values (100, 0, 2, current_date + 3, 'Speciale di Natale');
select t.eq((select is_special from public.v_tv_timeline
              where user_id = '11111111-1111-1111-1111-111111111111'
                and season_number = 0 and episode_number = 2),
            true, 'lo speciale in timeline c''e'' ed e'' marcato (§1.3)');

-- Le serie non attive non hanno uscite da mostrare.
update public.tv_show_state set user_status = 'dropped'
 where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 100;
-- Si guarda la serie abbandonata, non il totale: l'utente ne segue un'altra che esce oggi, e
-- pretendere zero righe misurerebbe quella invece di questa.
select t.eq((select count(*) from public.v_tv_timeline
              where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 100),
            0::bigint, 'una serie abbandonata sparisce dalla timeline');
select t.is_true((select count(*) > 0 from public.v_tv_timeline
                   where user_id = '11111111-1111-1111-1111-111111111111'),
            'ma le altre serie attive restano: sparisce quella, non la timeline');

-- L'isolamento fra utenti NON si puo' verificare qui: l'harness gira come superutente e la RLS
-- non si applica, quindi una query che sembra provarlo starebbe solo leggendo i dati legittimi
-- dell'altro utente. Si verifica invece la cosa da cui l'isolamento dipende davvero, ed e' anche
-- quella che un `create or replace` distratto porterebbe via in silenzio: senza
-- `security_invoker`, una vista di proprieta' di `postgres` scavalca la RLS di `tv_show_state` e
-- ogni utente vede il tracking di tutti.
select t.is_true(
  (select 'security_invoker=on' = any(c.reloptions)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'v_tv_tracking'),
  'v_tv_tracking e'' security_invoker: senza, scavalca la RLS di tv_show_state');
select t.is_true(
  (select 'security_invoker=on' = any(c.reloptions)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'v_tv_timeline'),
  'v_tv_timeline idem');

delete from public.tv_show_state
 where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 999999;

rollback;

\echo ''
\echo 'TUTTI I TEST PASSATI'
