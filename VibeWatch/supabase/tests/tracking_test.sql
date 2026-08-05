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
            'false', 'un job VECCHIO (stelle rinviate al blocco 9) resta false da solo: il suo report '
            'dice la verita'' di quando e'' girato');
-- §7.1 film (2026-08-02, import-write v7): la pipeline li importa. Il job 001 non ha righe
-- film: zeri VERI, con `film_supportati` a true — "non ne avevi", non "non supportato".
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'film_supportati',
            'true', 'i film ora si importano: supportati anche quando non ce ne sono');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'film_importati')::int,
            0, 'zero film visti importati per un job senza righe film: zero vero');

-- I quattro esiti della coda film su righe sintetiche: visto scritto, watchlist scritta,
-- gia' in lista (non e' una perdita: sta FUORI dall'elenco), non risolto (nell'elenco, col
-- titolo e il motivo — exact-match+anno o niente).
insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 90,
   '{"row_kind":"movie","movie_kind":"seen","title":"El Camino: A Breaking Bad Movie","tvtime_movie_uuid":"u-ec","happened_at":"2019-10-25 05:58:42"}'::jsonb,
   '{"tmdb_movie_id":559969}'::jsonb, 'written', null),
  ('aaaaaaaa-0000-4000-8000-000000000001', 91,
   '{"row_kind":"movie","movie_kind":"watchlist","title":"Haikyuu!! The Movie","tvtime_movie_uuid":"u-hk","happened_at":"2024-09-14 19:17:59"}'::jsonb,
   '{"tmdb_movie_id":1}'::jsonb, 'written', null),
  ('aaaaaaaa-0000-4000-8000-000000000001', 92,
   '{"row_kind":"movie","movie_kind":"watchlist","title":"The Invention of Lying","tvtime_movie_uuid":"u-il","happened_at":"2022-01-15 12:57:31"}'::jsonb,
   '{"tmdb_movie_id":2}'::jsonb, 'skipped', 'film: gia_in_lista'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 93,
   '{"row_kind":"movie","movie_kind":"seen","title":"メイドインアビス 旅立ちの夜明け","tvtime_movie_uuid":"u-ma","happened_at":"2020-06-21 15:06:56"}'::jsonb,
   null, 'unresolved', 'film: not_found');

select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'film_importati')::int,
            1, 'il report conta i film visti davvero scritti');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'film_watchlist_importati')::int,
            1, 'e la watchlist film, separata');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'film_gia_in_app')::int,
            1, 'un film gia'' in lista (o lapide) e'' una scelta, non una perdita');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'film_non_risolti')::int,
            1, 'un film non risolto si dichiara');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'film_non_risolti_elenco'->0->>'motivo',
            'film: not_found', 'con titolo e motivo, come per le serie');

-- Redesign 2.0: chi escludi durante la verifica non sparisce dal report. Resta nell'elenco
-- marcato `escluso`, ma FUORI dai contatori — quelli guidano l'inbox, e una scelta gia' presa
-- non e' lavoro rimasto da fare.
insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 94,
   '{"row_kind":"event","series_name":"Serie Esclusa","tvdb_series_id":"902","watched_at":"2020-02-02 00:00:00"}'::jsonb,
   null, 'skipped', 'escluso: utente'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 95,
   '{"row_kind":"movie","movie_kind":"seen","title":"Film Escluso","tvtime_movie_uuid":"u-fe","release_year":2018,"happened_at":"2019-03-12 21:00:00"}'::jsonb,
   null, 'skipped', 'escluso: utente');

select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'non_riconosciuti_serie')::int,
            1, 'una serie esclusa non torna a contare fra i titoli da verificare');
select t.eq(jsonb_array_length(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'non_riconosciuti_elenco'),
            2, 'ma resta nell''elenco: escluderla non la fa sparire senza traccia');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'non_riconosciuti_elenco'->1->>'escluso',
            'true', 'ed e'' marcata come esclusa, in fondo all''elenco');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'non_riconosciuti_elenco'->0->>'escluso',
            'false', 'mentre chi e'' ancora da verificare non lo e''');

select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'film_non_risolti')::int,
            1, 'stessa regola per i film: l''escluso non conta');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'film_non_risolti_elenco'->1->>'anno',
            '2018', 'il report porta l''anno del film: la card deve poter dire quale film e''');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'film_non_risolti_elenco'->1->>'visto_il',
            '2019-03-12 21:00:00', 'e la data di visione dell''export');

-- §7.5: i voti scritti davvero (import-write v5). Un secondo job coi quattro esiti della
-- pipeline nuova: stella scritta, gia' in app (non e' una perdita), non risolta, reaction
-- conservata. `voti_importati` qui e' STRUTTURALE: ogni stella processata → true.
-- `done` e non `running`: l'indice `import_jobs_one_open_per_user` ammette UN solo job
-- aperto per utente, e il job 001 qui sopra e' ancora running — l'indice fa il suo lavoro
-- anche nei test, ed e' una conferma gratis.
insert into public.import_jobs (id, user_id, source, status, phase)
values ('aaaaaaaa-0000-4000-8000-000000000003',
        '11111111-1111-1111-1111-111111111111', 'tvtime', 'done', 'done');

insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('aaaaaaaa-0000-4000-8000-000000000003', 0,
   '{"row_kind":"rating","kind":"star","tvdb_episode_id":"5001","star_rating":6}'::jsonb,
   null, 'written', null),
  ('aaaaaaaa-0000-4000-8000-000000000003', 1,
   '{"row_kind":"rating","kind":"star","tvdb_episode_id":"5002","star_rating":8}'::jsonb,
   null, 'skipped', 'voti: voto_gia_in_app'),
  ('aaaaaaaa-0000-4000-8000-000000000003', 2,
   '{"row_kind":"rating","kind":"star","tvdb_episode_id":"5003","star_rating":10}'::jsonb,
   null, 'skipped', 'voti: non_risolto'),
  ('aaaaaaaa-0000-4000-8000-000000000003', 3,
   '{"row_kind":"rating","kind":"reaction","tvdb_episode_id":"5001","reaction_id":27}'::jsonb,
   null, 'skipped', 'voti: reaction_conservata');

select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'voti_importati',
            'true', 'ogni stella processata dalla pipeline nuova: voti_importati e'' true');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'voti_stelle_importati')::int,
            1, 'le stelle scritte si contano');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'voti_stelle_gia_in_app')::int,
            1, 'un voto gia'' in app non e'' una perdita e conta a parte');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'voti_stelle_non_risolti')::int,
            1, 'una stella non risolta si dichiara');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'voti_reaction')::int,
            1, 'le reaction restano contate: conservate, mai convertite (la lookup e'' spenta)');

-- §7.1: i Favorites nel report (import-write v6). Quattro esiti: scritto, slot pieni,
-- gia' favorito in app, non risolto — piu' i film dichiarati dai totals della fase 2.
update public.import_jobs
   set totals = '{"favorite_movies_unsupported": 2}'::jsonb
 where id = 'aaaaaaaa-0000-4000-8000-000000000003';
insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('aaaaaaaa-0000-4000-8000-000000000003', 10,
   '{"row_kind":"favorite","tvdb_series_id":"300472","position":0}'::jsonb,
   '{"tmdb_show_id":100}'::jsonb, 'written', null),
  ('aaaaaaaa-0000-4000-8000-000000000003', 11,
   '{"row_kind":"favorite","tvdb_series_id":"300473","position":1}'::jsonb,
   '{"tmdb_show_id":101}'::jsonb, 'skipped', 'favorites: slot_pieni'),
  ('aaaaaaaa-0000-4000-8000-000000000003', 12,
   '{"row_kind":"favorite","tvdb_series_id":"300474","position":2}'::jsonb,
   '{"tmdb_show_id":102}'::jsonb, 'skipped', 'favorites: gia_favorito'),
  ('aaaaaaaa-0000-4000-8000-000000000003', 13,
   '{"row_kind":"favorite","tvdb_series_id":"300475","position":3}'::jsonb,
   null, 'unresolved', 'catalogo: not_found');

select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'favorites_supportati',
            'true', 'un job nuovo dichiara che i favorites si importano');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'favorites_importati')::int,
            1, 'i favorites scritti si contano');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'favorites_slot_pieni')::int,
            1, 'slot pieni: 4 slot sono il prodotto, non una perdita — ma si dichiara');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'favorites_gia_in_app')::int,
            1, 'una serie gia'' favorita in app non si duplica, e si dichiara');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'favorites_non_risolti')::int,
            1, 'un favorite non risolto si dichiara');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'favorite_film_non_supportati')::int,
            2, 'i favorite film si dichiarano non supportati, mai indovinati');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000003')->>'episodi_importati')::int,
            0, 'i favorites non si contano fra gli episodi');

-- §7.1: gli stati per-serie nel report. Quattro righe con i quattro esiti possibili:
-- applicato, lasciato com'era in app (non e' una perdita), non risolto, saltato in scrittura.
insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 5,
   '{"row_kind":"status","series_name":"Watchlist Applicata","tvdb_series_id":"910","user_status":"for_later"}'::jsonb,
   '{"tmdb_show_id":100}'::jsonb, 'written', null),
  ('aaaaaaaa-0000-4000-8000-000000000001', 6,
   '{"row_kind":"status","series_name":"Gia'' In App","tvdb_series_id":"911","user_status":"active"}'::jsonb,
   '{"tmdb_show_id":101}'::jsonb, 'skipped', 'stati: stato_gia_in_app'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 7,
   '{"row_kind":"status","series_name":"Watchlist Sparita","tvdb_series_id":"912","user_status":"for_later"}'::jsonb,
   null, 'unresolved', 'catalogo: not_found'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 8,
   '{"row_kind":"status","series_name":"Senza Show","tvdb_series_id":"913","user_status":"archived"}'::jsonb,
   null, 'skipped', 'stati: show_mancante');

select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'stati_supportati',
            'true', 'un job nuovo dichiara che gli stati si importano');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'stati_serie_importati')::int,
            1, 'gli stati applicati si contano');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'stati_serie_lasciati_in_app')::int,
            1, 'un active non sovrascritto non e'' una perdita, e si dichiara a parte');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'stati_serie_non_risolti')::int,
            2, 'non risolti E saltati in scrittura: tutto cio'' che non e'' arrivato');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'stati_non_risolti_elenco'->0->>'titolo',
            'Senza Show', 'anche per gli stati l''elenco nomina i titoli (ordine alfabetico)');
select t.eq(public.import_report('aaaaaaaa-0000-4000-8000-000000000001')
              ->'stati_non_risolti_elenco'->1->>'stato',
            'for_later', 'e dice quale stato si e'' perso');

-- Le righe di stato NON devono inquinare i conteggi degli episodi: stessi numeri di prima.
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'episodi_importati')::int,
            2, 'gli stati non si contano fra gli episodi');
select t.eq((public.import_report('aaaaaaaa-0000-4000-8000-000000000001')->>'non_riconosciuti_episodi')::int,
            1, 'ne'' fra i non riconosciuti degli episodi');


-- La fase 5 deve vedere TUTTE le serie toccate, a blocchi, senza saltarne.
select t.eq((select count(*) from public.import_touched_shows(
              'aaaaaaaa-0000-4000-8000-000000000001', 0, 200)),
            1::bigint, 'le serie toccate dal job sono quelle scritte, distinte');
select t.eq((select count(*) from public.import_touched_shows(
              'aaaaaaaa-0000-4000-8000-000000000001', 100, 200)),
            0::bigint, 'il checkpoint per id di serie non rilegge cio'' che ha gia'' fatto');

-- Un import che perde tutto non deve poter sembrare riuscito. Il job vuoto e' dell'utente 2:
-- l'utente 1 ha gia' un job aperto, e dal 20260802 l'indice `import_jobs_one_open_per_user`
-- vieta il secondo — questo test fissava una premessa che quella migration ha reso falsa.
insert into public.import_jobs (id, user_id, source, status, phase)
values ('aaaaaaaa-0000-4000-8000-000000000002',
        '22222222-2222-2222-2222-222222222222', 'tvtime', 'running', 'recomputing');
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

\echo ''
\echo '=== blocco 7: espansione di "serie vista per intero"'

-- Stato tutto proprio, utente e serie nuovi: i test sopra hanno mutato user_status, nomi di
-- episodi e catalogo piu' volte, ed ereditarli e' gia' costato due asserzioni sbagliate qui.
reset role;
insert into auth.users (id, email) values
  ('33333333-3333-3333-3333-333333333333', 'c@test');

-- 5 episodi usciti, 1 futuro, 1 speciale gia' uscito.
insert into public.tmdb_shows (tmdb_show_id, name, status)
values (700, 'Serie Vista Per Intero', 'Ended');
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date, runtime_minutes)
select 700, 1, n, current_date - 100, 42 from generate_series(1, 5) n;
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date, runtime_minutes)
values (700, 1, 6, current_date + 10, 42),
       (700, 0, 1, current_date - 200, 12);

set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

select t.eq(
  (public.expand_seen_shows_to_watch_events(
     jsonb_build_array(jsonb_build_object('tmdb_show_id', 700,
                                          'watched_at', (now() - interval '90 days')::text))
   )->>'events_written')::integer,
  5, 'espande ai soli episodi usciti e non speciali (5 su 7)');

select t.eq((select count(*)::integer from public.watch_events
              where user_id = '33333333-3333-3333-3333-333333333333' and season_number = 0), 0,
            'lo speciale non entra nel progresso (§1.3)');
select t.eq((select count(*)::integer from public.watch_events
              where user_id = '33333333-3333-3333-3333-333333333333' and episode_number = 6), 0,
            'l''episodio non ancora uscito non si marca visto: "l''ho visto tutto" non e'' una previsione');

-- §3.2: la data di visione vera non esiste in UserDefaults. Marcarla `exact` significherebbe
-- inventarla, ed e' proprio la distinzione per cui la colonna esiste.
select t.eq((select count(*)::integer from public.watch_events
              where user_id = '33333333-3333-3333-3333-333333333333'
                and watched_at_precision <> 'inferred'), 0,
            'ogni riga e'' inferred, mai exact');
select t.is_true((select bool_and(dedup_key like 'legacy:700:%')
                    from public.watch_events
                   where user_id = '33333333-3333-3333-3333-333333333333'),
            'dedup_key nella forma legacy:{show}:{stagione}:{episodio}');
select t.eq((select count(distinct runtime_seconds)::integer from public.watch_events
              where user_id = '33333333-3333-3333-3333-333333333333'), 1,
            'il runtime arriva dal catalogo, in secondi');
select t.eq((select max(runtime_seconds) from public.watch_events
              where user_id = '33333333-3333-3333-3333-333333333333'), 42 * 60,
            'e vale 42 minuti');

-- Il trigger ha fatto il suo mestiere: la serie risulta in pari, non "da iniziare".
select t.eq((select watched_count from public.tv_show_state
              where user_id = '33333333-3333-3333-3333-333333333333' and tmdb_show_id = 700), 5,
            'watched_count = 5');
select t.eq((select bucket from public.v_tv_tracking
              where user_id = '33333333-3333-3333-3333-333333333333' and tmdb_show_id = 700),
            'up_to_date',
            'bucket up_to_date — e'' tutto il punto: senza espansione sarebbe not_started');

-- Criterio 2 di §13, sulla forma che questa migrazione puo' assumere: l'utente reinstalla, il
-- flag locale si perde, la migrazione riparte.
select t.eq(
  (public.expand_seen_shows_to_watch_events(
     jsonb_build_array(jsonb_build_object('tmdb_show_id', 700))
   )->>'events_written')::integer,
  0, 'rigiocarla non scrive niente');
select t.eq((select count(*)::integer from public.watch_events
              where user_id = '33333333-3333-3333-3333-333333333333'), 5,
            'e non duplica');

-- Una serie che il catalogo non conosce si dichiara, non si finge migrata: scrivere zero episodi
-- visti sarebbe indistinguibile da "non l'ho mai iniziata".
select t.eq(
  public.expand_seen_shows_to_watch_events(
    jsonb_build_array(jsonb_build_object('tmdb_show_id', 999001))
  ),
  jsonb_build_object('events_written', 0, 'shows_without_catalog', jsonb_build_array(999001)),
  'una serie senza catalogo torna indietro nell''elenco, con zero eventi');

-- L'identita' non e' un parametro: la funzione e' definer, quindi la sola cosa che la tiene
-- ancorata al chiamante e' `auth.uid()`. Senza claim non deve scrivere niente a nome di nessuno.
-- Non si usa `t.rejects`: quel helper rilancia gli errori della classe `raise_exception`, che e'
-- esattamente quella di un `raise exception 'unauthenticated'`. Qui il blocco e' esplicito.
set local request.jwt.claim.sub = '';
do $$
begin
  perform public.expand_seen_shows_to_watch_events(
    jsonb_build_array(jsonb_build_object('tmdb_show_id', 700)));
  raise exception 'FAIL  senza utente autenticato la funzione ha scritto lo stesso';
exception when raise_exception then
  if sqlerrm <> 'unauthenticated' then raise; end if;
  raise notice 'ok    senza utente autenticato la funzione rifiuta';
end $$;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

-- I permessi si leggono su `proacl`, non sul revoke che si e' scritto: Supabase concede EXECUTE
-- ad anon/authenticated con un `alter default privileges` esplicito, e revocare al solo PUBLIC
-- lascia i grant espliciti al loro posto. E' il difetto gia' trovato su `import_touched_shows`.
select t.eq(
  (select count(*)::integer from pg_proc p
     where p.proname = 'expand_seen_shows_to_watch_events'
       and array_to_string(p.proacl, ',') like '%anon=X%'),
  0, 'anon non puo'' eseguire l''espansione (letto da proacl, non dal revoke)');
select t.is_true(
  (select array_to_string(p.proacl, ',') like '%authenticated=X%' from pg_proc p
    where p.proname = 'expand_seen_shows_to_watch_events'),
  'authenticated invece si: la chiama il client durante la migrazione');

-- E l'utente dell'altro blocco non ha ereditato niente.
select t.eq((select count(*)::integer from public.watch_events
              where user_id = '11111111-1111-1111-1111-111111111111'
                and tmdb_show_id = 700), 0,
            'l''espansione ha scritto solo per chi l''ha chiesta');

\echo ''
\echo '=== fusione ListsView-Tracking: unsee_tv_show'

-- Il contraltare di "vista tutta": l'utente 3333 ha appena 5 eventi vivi sulla serie 700.
select t.eq((public.unsee_tv_show(700)->>'events_removed')::integer, 5,
            'unsee mette la lapide su TUTTI gli eventi vivi della serie');
select t.eq((select count(*)::integer from public.watch_events
              where user_id = '33333333-3333-3333-3333-333333333333'
                and tmdb_show_id = 700 and deleted_at is null), 0,
            'nessun evento vivo dopo unsee');
select t.eq((select user_status from public.tv_show_state
              where user_id = '33333333-3333-3333-3333-333333333333'
                and tmdb_show_id = 700),
            'dropped',
            'la serie e'' dropped: senza, il ricalcolo la farebbe ricomparire come not_started');
select t.eq((select watched_count from public.tv_show_state
              where user_id = '33333333-3333-3333-3333-333333333333'
                and tmdb_show_id = 700),
            0, 'i contatori sono ricalcolati sugli eventi con lapide');
select t.eq((public.unsee_tv_show(700)->>'events_removed')::integer, 0,
            'rigiocare unsee e'' un no-op dichiarato, non un errore');

-- Stessa guardia dell'espansione: definer ancorata ad auth.uid(), senza claim rifiuta.
set local request.jwt.claim.sub = '';
do $$
begin
  perform public.unsee_tv_show(700);
  raise exception 'FAIL  senza utente autenticato unsee ha scritto lo stesso';
exception when sqlstate '28000' then
  raise notice 'ok    senza utente autenticato unsee rifiuta';
end $$;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

select t.eq(
  (select count(*)::integer from pg_proc p
     where p.proname = 'unsee_tv_show'
       and array_to_string(p.proacl, ',') like '%anon=X%'),
  0, 'anon non puo'' eseguire unsee (letto da proacl)');
select t.is_true(
  (select array_to_string(p.proacl, ',') like '%authenticated=X%' from pg_proc p
    where p.proname = 'unsee_tv_show'),
  'authenticated si'': e'' l''azione "togli dalla lista Seen" del client');

\echo ''
\echo '=== fusione ListsView-Tracking: backfill watchlist legacy'

-- Come owner: il backfill e' negato ai ruoli client DI PROPOSITO (e' il lavoro della migration),
-- e la riga di proacl piu' sotto e' il test che resti cosi'.
reset role;

-- Watchlist legacy dell'utente 1111: una serie TV nuova (800), una che ha GIA' uno stato scelto
-- (100, for_later dal blocco sopra), un film (che non c'entra), una riga cancellata (801).
insert into public.lists (id, user_id, type) values
  ('bbbbbbbb-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111', 'watchlist');
insert into public.list_items (list_id, user_id, media_id, media_type, deleted_at) values
  ('bbbbbbbb-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111', 800, 'tv', null),
  ('bbbbbbbb-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111', 100, 'tv', null),
  ('bbbbbbbb-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111', 500, 'movie', null),
  ('bbbbbbbb-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111', 801, 'tv', now());

select t.eq((public.backfill_watchlist_tracking()->>'inserted')::integer, 1,
            'nasce solo la riga che manca: la serie nuova');
select t.eq((select user_status from public.tv_show_state
              where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 800),
            'active', 'la serie in watchlist diventa "Da iniziare"');
-- La 100 arriva qui 'dropped' (il test della timeline sopra l'ha abbandonata): proprio il caso
-- che il backfill non deve toccare — rimetterla 'active' farebbe ricomparire una serie
-- abbandonata solo perche' un tempo stava in watchlist.
select t.eq((select user_status from public.tv_show_state
              where user_id = '11111111-1111-1111-1111-111111111111' and tmdb_show_id = 100),
            'dropped', 'uno stato gia'' scelto NON si sovrascrive');
select t.eq((select count(*)::integer from public.tv_show_state
              where tmdb_show_id in (500, 801)), 0,
            'film e righe cancellate non producono stato tracking');
select t.eq((public.backfill_watchlist_tracking()->>'inserted')::integer, 0,
            'rigiocare il backfill non fa niente: idempotente');

select t.eq(
  (select count(*)::integer from pg_proc p
     where p.proname = 'backfill_watchlist_tracking'
       and (array_to_string(p.proacl, ',') like '%anon=X%'
         or array_to_string(p.proacl, ',') like '%authenticated=X%')),
  0, 'il backfill e'' solo service: nessun ruolo client su proacl');

reset role;

\echo ''
\echo '=== Task 4: il tracking si aggiorna quando esce un episodio nuovo'

-- Una serie finita e vista tutta: l'utente e' "in pari" e la serie risulta completata.
insert into public.tmdb_shows (tmdb_show_id, name, status, in_production, number_of_seasons)
values (900, 'Rinnovata', 'Ended', false, 1);
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date)
values (900, 1, 1, current_date - 400), (900, 1, 2, current_date - 393);
insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source)
values ('11111111-1111-1111-1111-111111111111', 'tv', 900, 1, 1, now() - interval '1 year', 'manual'),
       ('11111111-1111-1111-1111-111111111111', 'tv', 900, 1, 2, now() - interval '1 year', 'manual');

select t.eq((select bucket from public.v_tv_tracking where tmdb_show_id = 900), 'up_to_date',
            'in partenza la serie e'' in pari');

-- La serie viene rinnovata e il catalogo, rinfrescato dal cron notturno, impara la stagione 2.
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date)
values (900, 2, 1, current_date - 1);

select t.is_true((select public.refresh_backlog_since() > 0),
                 'il job ricalcola dopo il rinfresco del catalogo');
select t.eq((select bucket from public.v_tv_tracking where tmdb_show_id = 900), 'up_next',
            'la serie in pari torna in "continua a guardare" da sola');

-- Una serie messa in pausa: prima di questo giro `refresh_backlog_since` guardava solo le
-- 'active', quindi chi riprendeva una serie snoozata la ritrovava com'era il giorno dello snooze.
insert into public.tmdb_shows (tmdb_show_id, name, status, in_production, number_of_seasons)
values (901, 'In pausa', 'Returning Series', true, 1);
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, air_date)
values (901, 1, 1, current_date - 100), (901, 1, 2, current_date - 2);
insert into public.watch_events
  (user_id, media_type, tmdb_show_id, season_number, episode_number, watched_at, source)
values ('11111111-1111-1111-1111-111111111111', 'tv', 901, 1, 1, now() - interval '90 days', 'manual');
update public.tv_show_state set user_status = 'for_later', backlog_since = null
 where tmdb_show_id = 901;

select t.is_true((select public.refresh_backlog_since() > 0),
                 'il job ricalcola anche le serie in pausa');
select t.is_true((select backlog_since is not null from public.tv_show_state where tmdb_show_id = 901),
                 'una serie in pausa non resta ferma al giorno dello snooze');

\echo ''
\echo '=== Task 4: la selezione del rinfresco notturno'

-- Una serie seguita di cui NON abbiamo il catalogo: e'' la priorita'' massima (self-heal).
insert into public.tv_show_state (user_id, tmdb_show_id, user_status)
values ('11111111-1111-1111-1111-111111111111', 902, 'active')
on conflict do nothing;

select t.is_true(
  (select 902 = any(array(select tmdb_show_id from public.catalog_shows_needing_refresh(400)))),
  'una serie seguita senza catalogo entra nella selezione');

-- Una serie chiusa e ferma da mesi: il TTL a 90 giorni non la farebbe mai rinfrescare, ed e''
-- esattamente il caso della serie rinnovata dopo la chiusura.
update public.tmdb_shows
   set refreshed_at = now() - interval '60 days', next_refresh_at = now() + interval '30 days'
 where tmdb_show_id = 900;

select t.is_true(
  (select 900 = any(array(select tmdb_show_id from public.catalog_shows_needing_refresh(400)))),
  'una serie "ended" ferma da oltre 30 giorni entra comunque nella selezione');

select t.eq((select count(*)::integer from public.catalog_shows_needing_refresh(0)), 0,
            'il limite viene rispettato');

-- La selezione legge lo stato di tutti: esposta direbbe a chiunque cosa guarda la gente.
select t.eq(
  (select count(*)::integer from pg_proc p
     where p.proname = 'catalog_shows_needing_refresh'
       and (array_to_string(p.proacl, ',') like '%anon=X%'
         or array_to_string(p.proacl, ',') like '%authenticated=X%')),
  0, 'la selezione e'' solo service: nessun ruolo client su proacl');

reset role;

rollback;

\echo ''
\echo 'TUTTI I TEST PASSATI'
