-- SPEC v3 §7.2 — l'ingresso dell'import: `create_import_job`, `retry_import_job`,
-- `import_apply_mutations` (migration 20260802100000).
--
-- Si esegue con supabase/tests/run.sh. Una asserzione fallita interrompe tutto.

\set ON_ERROR_STOP on
\set QUIET 1
\pset pager off
\pset tuples_only on
\pset footer off

begin;
set local timezone = 'UTC';

insert into auth.users (id, email) values
  ('cccccccc-0000-0000-0000-000000000001', 'ia@test'),
  ('cccccccc-0000-0000-0000-000000000002', 'ib@test');

-- Il file "caricato" dell'utente 1, piu' un file nella SUA cartella ma caricato da un altro:
-- il secondo esiste per provare che il controllo sull'owner non e' decorativo.
insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('imports', 'cccccccc-0000-0000-0000-000000000001/export.zip',
   'cccccccc-0000-0000-0000-000000000001', null),
  ('imports', 'cccccccc-0000-0000-0000-000000000001/intruso.zip',
   'cccccccc-0000-0000-0000-000000000002', null),
  ('imports', 'cccccccc-0000-0000-0000-000000000001/secondo.zip',
   null, 'cccccccc-0000-0000-0000-000000000001');

\echo ''
\echo '=== create_import_job: la forma del path'

set local role authenticated;
set local request.jwt.claim.sub = 'cccccccc-0000-0000-0000-000000000001';

select t.eq((select public.create_import_job(
              'cccccccc-0000-0000-0000-000000000002/export.zip')->>'reason'),
            'bad_path', 'la cartella di un altro e'' bad_path, non un tentativo');

select t.eq((select public.create_import_job(
              'cccccccc-0000-0000-0000-000000000001/export.csv')->>'reason'),
            'bad_path', 'non-zip rifiutato');

select t.eq((select public.create_import_job(
              'cccccccc-0000-0000-0000-000000000001/a/b.zip')->>'reason'),
            'bad_path', 'un solo segmento dentro la cartella: niente sottocartelle');

select t.eq((select public.create_import_job(null)->>'reason'),
            'bad_path', 'path nullo rifiutato');

\echo ''
\echo '=== create_import_job: il file deve esistere ed essere del chiamante'

select t.eq((select public.create_import_job(
              'cccccccc-0000-0000-0000-000000000001/manca.zip')->>'reason'),
            'upload_not_found', 'path ben formato ma file mai caricato');

select t.eq((select public.create_import_job(
              'cccccccc-0000-0000-0000-000000000001/intruso.zip')->>'reason'),
            'upload_not_found',
            'file nella propria cartella ma caricato da un altro: l''owner decide');

\echo ''
\echo '=== create_import_job: il caso buono, e il doppio job'

select t.eq((select public.create_import_job(
              'cccccccc-0000-0000-0000-000000000001/export.zip')->>'ok'),
            'true', 'lo zip proprio, caricato, crea il job');

select t.eq((select count(*)::integer from public.import_jobs
              where user_id = 'cccccccc-0000-0000-0000-000000000001'
                and phase = 'uploaded' and status = 'running' and source = 'tvtime'),
            1, 'il job nasce uploaded/running/tvtime, e la RLS lo mostra al proprietario');

-- `owner_id` (text) al posto di `owner` (uuid): la seconda strada del controllo. Deve fallire
-- per il doppio job, NON per l'owner — quindi la ragione giusta e' already_running.
select t.eq((select public.create_import_job(
              'cccccccc-0000-0000-0000-000000000001/secondo.zip')->>'reason'),
            'already_running', 'un solo import aperto per utente: decide l''indice, non un if');

\echo ''
\echo '=== retry_import_job'

select t.eq((select public.retry_import_job(
              (select id from public.import_jobs
                where user_id = 'cccccccc-0000-0000-0000-000000000001'))->>'reason'),
            'not_found', 'un job running non si "riprova": solo failed');

reset role;
update public.import_jobs set status = 'failed', error = 'guasto simulato'
 where user_id = 'cccccccc-0000-0000-0000-000000000001';

-- L'id si cattura da postgres, PRIMA di impersonare l'altro utente: sotto RLS la subquery
-- tornerebbe null e il test proverebbe "retry di un id nullo", non "retry del job altrui".
select id as job1_id from public.import_jobs
 where user_id = 'cccccccc-0000-0000-0000-000000000001' and status = 'failed'
\gset

set local role authenticated;
set local request.jwt.claim.sub = 'cccccccc-0000-0000-0000-000000000002';
select t.eq((select public.retry_import_job(:'job1_id'::uuid)->>'reason'),
            'not_found', 'il job di un altro: stessa risposta di "inesistente", niente oracolo');

set local request.jwt.claim.sub = 'cccccccc-0000-0000-0000-000000000001';
select t.eq((select public.retry_import_job(
              (select id from public.import_jobs
                where user_id = 'cccccccc-0000-0000-0000-000000000001'
                  and status = 'failed'))->>'ok'),
            'true', 'il proprio job failed riparte');

select t.eq((select count(*)::integer from public.import_jobs
              where user_id = 'cccccccc-0000-0000-0000-000000000001'
                and status = 'running' and error is null),
            1, 'running di nuovo, errore azzerato, fase intatta (checkpoint §7.2)');

-- Con un job running e uno failed, il retry del failed deve sbattere sull'indice unico e
-- rispondere already_running — non un 23505 da interpretare.
reset role;
update public.import_jobs set status = 'failed', error = 'x'
 where user_id = 'cccccccc-0000-0000-0000-000000000001';
insert into public.import_jobs (user_id, source, storage_path, status, phase)
values ('cccccccc-0000-0000-0000-000000000001', 'tvtime',
        'cccccccc-0000-0000-0000-000000000001/secondo.zip', 'running', 'uploaded');

set local role authenticated;
set local request.jwt.claim.sub = 'cccccccc-0000-0000-0000-000000000001';
select t.eq((select public.retry_import_job(
              (select id from public.import_jobs
                where user_id = 'cccccccc-0000-0000-0000-000000000001'
                  and status = 'failed'))->>'reason'),
            'already_running', 'retry con un altro job aperto: esito, non 23505');

\echo ''
\echo '=== i grant, su proacl'

reset role;

select t.is_true(has_function_privilege('authenticated',
              'public.create_import_job(text)', 'execute'),
            'create_import_job e'' del client autenticato');
select t.is_true(not has_function_privilege('anon',
              'public.create_import_job(text)', 'execute'),
            'ma non di anon');
select t.is_true(has_function_privilege('authenticated',
              'public.retry_import_job(uuid)', 'execute'),
            'retry_import_job e'' del client autenticato');
select t.is_true(not has_function_privilege('anon',
              'public.retry_import_job(uuid)', 'execute'),
            'ma non di anon');

select t.is_true(not has_function_privilege('authenticated',
              'public.import_apply_mutations(uuid, jsonb)', 'execute'),
            'import_apply_mutations NON e'' del client: sarebbe impersonazione libera');
select t.is_true(not has_function_privilege('anon',
              'public.import_apply_mutations(uuid, jsonb)', 'execute'),
            'e nemmeno di anon');
select t.is_true(has_function_privilege('service_role',
              'public.import_apply_mutations(uuid, jsonb)', 'execute'),
            'solo il service la esegue');

\echo ''
\echo '=== import_apply_mutations: l''identita'' dentro la chiamata e'' il proprietario'
-- Ultimo di proposito: `set_config(..., true)` e' locale alla TRANSAZIONE, e questo test e'
-- tutto una transazione — dopo la chiamata, le claim impostate resterebbero addosso ai test
-- successivi. In produzione la transazione e' la singola richiesta PostgREST e muore con lei.

-- `apply_mutations` vero qui non c'e' (le sue migration presuppongono lo schema di produzione):
-- lo sostituisce una sonda che registra chi e' `auth.uid()` al momento della chiamata — che e'
-- esattamente la proprieta' da provare.
create table pg_temp.probe (uid uuid);
create or replace function public.apply_mutations(batch jsonb)
returns void language sql as
$$ insert into pg_temp.probe select auth.uid(); $$;

-- Le claim dei test precedenti sono transaction-local ma la transazione e' questa: si
-- azzerano a mano, o "il service non ha un auth.uid()" erediterebbe l'utente 1.
set local request.jwt.claim.sub = '';
set local role service_role;
select t.eq((select auth.uid()), null::uuid, 'il service non ha un auth.uid()');

select public.import_apply_mutations('cccccccc-0000-0000-0000-000000000001', '[]'::jsonb);

-- La sonda si legge da postgres: e' sua. Il pezzo da provare come service e' gia' successo.
reset role;
select t.eq((select uid from pg_temp.probe),
            'cccccccc-0000-0000-0000-000000000001'::uuid,
            'dentro apply_mutations l''identita'' e'' il proprietario del job');

select t.rejects(
  $$select public.import_apply_mutations(null, '[]'::jsonb)$$,
  'p_user nullo e'' un errore, non un no-op');

rollback;

\echo ''
\echo 'TUTTI I TEST PASSATI'
