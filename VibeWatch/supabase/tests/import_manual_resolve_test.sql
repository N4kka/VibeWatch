-- SPEC v3 §7.4 — riapertura atomica della risoluzione manuale.
--
-- La scelta della serie modifica tre pezzi di stato (mappa condivisa, staging e job). Se il
-- job non puo' riaprirsi, nessuno degli altri due puo' restare modificato.

\set ON_ERROR_STOP on
\set QUIET 1
\pset pager off
\pset tuples_only on
\pset footer off

begin;
set local timezone = 'UTC';

insert into auth.users (id, email) values
  ('dddddddd-0000-0000-0000-000000000001', 'manual-ok@test'),
  ('dddddddd-0000-0000-0000-000000000002', 'manual-conflict@test'),
  ('dddddddd-0000-0000-0000-000000000003', 'manual-wrong-rating@test'),
  ('dddddddd-0000-0000-0000-000000000004', 'manual-batch@test');

insert into public.import_jobs (id, user_id, source, status, phase, totals)
values (
  'dddddddd-1000-0000-0000-000000000001',
  'dddddddd-0000-0000-0000-000000000001',
  'tvtime', 'done', 'done',
  '{"unresolved": 2, "ratings_not_written": 1}'::jsonb
);

insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('dddddddd-1000-0000-0000-000000000001', 1,
   '{"row_kind":"event","tvdb_series_id":"1001","tvdb_episode_id":"5001"}',
   '{"vecchio":true}', 'unresolved', 'catalogo: not_found'),
  ('dddddddd-1000-0000-0000-000000000001', 2,
   '{"row_kind":"rating","tvdb_episode_id":"5001"}',
   '{"vecchio":true}', 'skipped', 'voti: non_risolto'),
  ('dddddddd-1000-0000-0000-000000000001', 3,
   '{"row_kind":"event","tvdb_series_id":"9999","tvdb_episode_id":"5999"}',
   null, 'unresolved', 'catalogo: not_found');

insert into public.tvdb_tmdb_map
  (tvdb_id, entity_type, resolution, method, resolved_at)
values (1001, 'series', 'not_found', 'tmdb_find', now());

\echo ''
\echo '=== import_reopen_manual_resolution: caso atomico riuscito'

set local role service_role;
select t.eq(
  (select public.import_reopen_manual_resolution(
    'dddddddd-1000-0000-0000-000000000001', 1001, 2001,
    array[1, 2], '{"unresolved":0,"ratings_not_written":0}'::jsonb)->>'ok'),
  'true', 'la riapertura valida riesce');
reset role;

select t.eq(
  (select phase || '/' || status from public.import_jobs
    where id = 'dddddddd-1000-0000-0000-000000000001'),
  'resolving/running', 'il job riparte da resolving');
select t.eq(
  (select checkpoint #>> '{manual_episode_context,tvdb_series_id}'
     from public.import_jobs where id = 'dddddddd-1000-0000-0000-000000000001'),
  '1001', 'il checkpoint autorizza il retry esatto della serie scelta');
select t.eq(
  (select count(*)::integer from public.import_staging
    where job_id = 'dddddddd-1000-0000-0000-000000000001'
      and row_index in (1, 2) and status = 'pending'
      and resolved is null and error is null),
  2, 'solo le righe richieste tornano pending senza identita'' ereditata');
select t.eq(
  (select status from public.import_staging
    where job_id = 'dddddddd-1000-0000-0000-000000000001' and row_index = 3),
  'unresolved', 'le righe non richieste restano intatte');
select t.eq(
  (select resolution || '/' || tmdb_show_id::text || '/' || method
     from public.tvdb_tmdb_map where tvdb_id = 1001 and entity_type = 'series'),
  'found/2001/manual', 'la sola mappa serie diventa manuale');

\echo ''
\echo '=== import_reopen_manual_resolution: conflitto e rollback'

insert into public.import_jobs (id, user_id, source, status, phase, totals) values
  ('dddddddd-1000-0000-0000-000000000002',
   'dddddddd-0000-0000-0000-000000000002', 'tvtime', 'done', 'done',
   '{"unresolved":1}'::jsonb),
  ('dddddddd-1000-0000-0000-000000000003',
   'dddddddd-0000-0000-0000-000000000002', 'tvtime', 'running', 'uploaded', '{}'::jsonb);

insert into public.import_staging (job_id, row_index, raw, resolved, status, error)
values ('dddddddd-1000-0000-0000-000000000002', 1,
        '{"row_kind":"event","tvdb_series_id":"1002","tvdb_episode_id":"5002"}',
        '{"vecchio":true}', 'unresolved', 'catalogo: not_found');

insert into public.tvdb_tmdb_map
  (tvdb_id, entity_type, resolution, method, resolved_at)
values (1002, 'series', 'not_found', 'tmdb_find', now());

set local role service_role;
select t.eq(
  (select public.import_reopen_manual_resolution(
    'dddddddd-1000-0000-0000-000000000002', 1002, 2002,
    array[1], '{"unresolved":0}'::jsonb)->>'reason'),
  'another_job_open', 'il vincolo su un altro job aperto diventa un esito');
reset role;

select t.eq(
  (select phase || '/' || status from public.import_jobs
    where id = 'dddddddd-1000-0000-0000-000000000002'),
  'done/done', 'il job originale resta concluso');
select t.eq(
  (select status || '/' || error from public.import_staging
    where job_id = 'dddddddd-1000-0000-0000-000000000002' and row_index = 1),
  'unresolved/catalogo: not_found', 'il conflitto non nasconde la riga dal report');
select t.eq(
  (select resolution from public.tvdb_tmdb_map
    where tvdb_id = 1002 and entity_type = 'series'),
  'not_found', 'anche la mappa condivisa viene ripristinata');
select t.eq(
  (select totals->>'unresolved' from public.import_jobs
    where id = 'dddddddd-1000-0000-0000-000000000002'),
  '1', 'i conteggi del report restano intatti');

\echo ''
\echo '=== import_reopen_manual_resolution: un voto non attraversa un conflitto episodio'

insert into public.import_jobs (id, user_id, source, status, phase, totals)
values ('dddddddd-1000-0000-0000-000000000004',
        'dddddddd-0000-0000-0000-000000000003', 'tvtime', 'done', 'done',
        '{"unresolved":1,"ratings_not_written":1}'::jsonb);
insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('dddddddd-1000-0000-0000-000000000004', 1,
   '{"row_kind":"event","tvdb_series_id":"1003","tvdb_episode_id":"5003"}',
   null, 'unresolved', 'catalogo: conflitto_serie'),
  ('dddddddd-1000-0000-0000-000000000004', 2,
   '{"row_kind":"rating","tvdb_episode_id":"5003"}',
   null, 'skipped', 'voti: non_risolto');
insert into public.tvdb_tmdb_map
  (tvdb_id, entity_type, tmdb_show_id, season_number, episode_number,
   resolution, method, resolved_at)
values
  (1003, 'series', null, null, null, 'not_found', 'tmdb_find', now()),
  (5003, 'episode', 9999, 1, 1, 'found', 'tmdb_find', now());

set local role service_role;
select t.eq(
  (select public.import_reopen_manual_resolution(
    'dddddddd-1000-0000-0000-000000000004', 1003, 2003,
    array[1, 2], '{"unresolved":0,"ratings_not_written":0}'::jsonb)->>'reason'),
  'staging_changed', 'la RPC rifiuta un voto gia'' found su un altro show');
reset role;

select t.eq(
  (select status from public.import_staging
    where job_id = 'dddddddd-1000-0000-0000-000000000004' and row_index = 2),
  'skipped', 'il voto resta dichiarato non scritto');
select t.eq(
  (select phase || '/' || status from public.import_jobs
    where id = 'dddddddd-1000-0000-0000-000000000004'),
  'done/done', 'il piano difensivamente rifiutato fa rollback anche del job');

\echo ''
\echo '=== import_reopen_manual_resolutions: due serie, una sola riapertura'

insert into public.import_jobs (id, user_id, source, status, phase, totals)
values ('dddddddd-1000-0000-0000-000000000005',
        'dddddddd-0000-0000-0000-000000000004', 'tvtime', 'done', 'done',
        '{"unresolved":2,"statuses_unresolved":1,"ratings_not_written":1}'::jsonb);
insert into public.import_staging (job_id, row_index, raw, resolved, status, error) values
  ('dddddddd-1000-0000-0000-000000000005', 1,
   '{"row_kind":"event","tvdb_series_id":"1101","tvdb_episode_id":"5101"}',
   null, 'unresolved', 'catalogo: not_found'),
  ('dddddddd-1000-0000-0000-000000000005', 2,
   '{"row_kind":"rating","tvdb_episode_id":"5101"}',
   null, 'skipped', 'voti: non_risolto'),
  ('dddddddd-1000-0000-0000-000000000005', 3,
   '{"row_kind":"event","tvdb_series_id":"1102","tvdb_episode_id":"5102"}',
   null, 'unresolved', 'catalogo: ambiguous'),
  ('dddddddd-1000-0000-0000-000000000005', 4,
   '{"row_kind":"status","tvdb_series_id":"1102"}',
   null, 'unresolved', 'catalogo: not_found'),
  ('dddddddd-1000-0000-0000-000000000005', 5,
   '{"row_kind":"event","tvdb_series_id":"9999","tvdb_episode_id":"5999"}',
   null, 'unresolved', 'catalogo: not_found');
insert into public.tvdb_tmdb_map
  (tvdb_id, entity_type, resolution, method, resolved_at)
values
  (1101, 'series', 'not_found', 'tmdb_find', now()),
  (1102, 'series', 'ambiguous', 'tmdb_find', now());

set local role service_role;
select t.eq(
  (select public.import_reopen_manual_resolutions(
    'dddddddd-1000-0000-0000-000000000005',
    '[{"tvdb_series_id":1101,"tmdb_show_id":2101},
      {"tvdb_series_id":1102,"tmdb_show_id":2102}]'::jsonb,
    array[1, 2, 3, 4],
    '{"unresolved":0,"statuses_unresolved":0,"ratings_not_written":0}'::jsonb)->>'ok'),
  'true', 'l intero batch riapre il job con una sola chiamata');
reset role;

select t.eq(
  (select phase || '/' || status from public.import_jobs
    where id = 'dddddddd-1000-0000-0000-000000000005'),
  'resolving/running', 'il batch avvia un solo giro resolving');
select t.eq(
  (select jsonb_array_length(checkpoint->'manual_episode_contexts')
     from public.import_jobs where id = 'dddddddd-1000-0000-0000-000000000005'),
  2, 'il checkpoint conserva entrambe le serie');
select t.eq(
  (select checkpoint #>> '{manual_episode_contexts,1,tmdb_show_id}'
     from public.import_jobs where id = 'dddddddd-1000-0000-0000-000000000005'),
  '2102', 'ogni serie conserva il proprio show TMDB atteso');
select t.eq(
  (select count(*)::integer from public.import_staging
    where job_id = 'dddddddd-1000-0000-0000-000000000005'
      and row_index in (1, 2, 3, 4) and status = 'pending'
      and resolved is null and error is null),
  4, 'eventi, stato e voto delle serie scelte tornano pending insieme');
select t.eq(
  (select status from public.import_staging
    where job_id = 'dddddddd-1000-0000-0000-000000000005' and row_index = 5),
  'unresolved', 'un titolo non selezionato resta nel report');
select t.eq(
  (select string_agg(tvdb_id::text || ':' || tmdb_show_id::text, ',' order by tvdb_id)
     from public.tvdb_tmdb_map where entity_type = 'series' and tvdb_id in (1101, 1102)),
  '1101:2101,1102:2102', 'le due mappe serie vengono applicate nella stessa transazione');

set local role service_role;
select t.eq(
  (select public.import_reopen_manual_resolutions(
    'dddddddd-1000-0000-0000-000000000005',
    '[{"tvdb_series_id":1101,"tmdb_show_id":2101},
      {"tvdb_series_id":1101,"tmdb_show_id":9999}]'::jsonb,
    array[1], '{}'::jsonb)->>'reason'),
  'invalid_plan', 'una serie duplicata non può dichiarare due identità');
reset role;

\echo ''
\echo '=== import_reopen_manual_resolution: grant minimo'

select t.is_true(not has_function_privilege(
  'authenticated', 'public.import_reopen_manual_resolution(uuid,bigint,integer,integer[],jsonb)',
  'execute'), 'il client non puo'' riaprire direttamente un import');
select t.is_true(has_function_privilege(
  'service_role', 'public.import_reopen_manual_resolution(uuid,bigint,integer,integer[],jsonb)',
  'execute'), 'solo il service role puo'' applicare il piano atomico');
select t.is_true(not has_function_privilege(
  'authenticated', 'public.import_reopen_manual_resolutions(uuid,jsonb,integer[],jsonb)',
  'execute'), 'il client non puo'' applicare direttamente un batch');
select t.is_true(has_function_privilege(
  'service_role', 'public.import_reopen_manual_resolutions(uuid,jsonb,integer[],jsonb)',
  'execute'), 'solo il service role puo'' applicare il batch atomico');

rollback;
