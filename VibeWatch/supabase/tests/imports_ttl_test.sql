-- SPEC v3 §7.2 — il TTL del bucket `imports`: `imports_stale_uploads`
-- (migration 20260802150000). La cancellazione vera sta nella Edge Function `imports-cleanup`
-- e si collauda in produzione; qui si prova la meta' SQL: CHI e' candidato, e chi puo'
-- chiederlo.
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
  ('dddddddd-0000-0000-0000-000000000001', 'ttl@test');

-- Quattro file, quattro destini:
--   vecchio.zip  oltre il TTL, nessun job che lo tiene       -> candidato
--   fresco.zip   dentro il TTL                               -> no
--   vivo.zip     oltre il TTL ma con un job `running` sopra  -> no: la fase 2 lo sta leggendo
--   morto.zip    oltre il TTL con un job `failed` sopra      -> candidato: il TTL e' la
--                promessa di §7.2, un retry tardivo rispondera' upload_not_found (visibile)
insert into storage.objects (bucket_id, name, owner, created_at) values
  ('imports', 'dddddddd-0000-0000-0000-000000000001/vecchio.zip',
   'dddddddd-0000-0000-0000-000000000001', now() - interval '8 days'),
  ('imports', 'dddddddd-0000-0000-0000-000000000001/fresco.zip',
   'dddddddd-0000-0000-0000-000000000001', now() - interval '1 day'),
  ('imports', 'dddddddd-0000-0000-0000-000000000001/vivo.zip',
   'dddddddd-0000-0000-0000-000000000001', now() - interval '30 days'),
  ('imports', 'dddddddd-0000-0000-0000-000000000001/morto.zip',
   'dddddddd-0000-0000-0000-000000000001', now() - interval '30 days');

-- Un bucket diverso con un file antico: la funzione guarda SOLO `imports`.
insert into storage.objects (bucket_id, name, owner, created_at) values
  ('avatars', 'dddddddd-0000-0000-0000-000000000001/avatar.jpg',
   'dddddddd-0000-0000-0000-000000000001', now() - interval '400 days');

insert into public.import_jobs (user_id, status, phase, storage_path) values
  ('dddddddd-0000-0000-0000-000000000001', 'running', 'parsing',
   'dddddddd-0000-0000-0000-000000000001/vivo.zip');
-- Il job failed sul quarto file. L'indice `import_jobs_one_open_per_user` conta solo
-- running/paused, quindi la coppia running+failed per lo stesso utente e' legittima.
insert into public.import_jobs (user_id, status, phase, storage_path, error) values
  ('dddddddd-0000-0000-0000-000000000001', 'failed', 'resolving',
   'dddddddd-0000-0000-0000-000000000001/morto.zip', 'collaudo');

\echo ''
\echo '=== imports_stale_uploads: chi e'' candidato'

select t.eq(
  (select count(*)::integer from public.imports_stale_uploads()),
  2, 'col TTL di default (7 giorni): vecchio.zip e morto.zip, nient''altro');

select t.is_true(
  (select bool_and(name in ('dddddddd-0000-0000-0000-000000000001/vecchio.zip',
                            'dddddddd-0000-0000-0000-000000000001/morto.zip'))
     from public.imports_stale_uploads()),
  'i candidati sono esattamente i due attesi: il fresco, il vivo e l''altro bucket restano fuori');

select t.eq(
  (select count(*)::integer from public.imports_stale_uploads(interval '31 days')),
  0, 'con un TTL piu'' lungo di ogni file non c''e'' nessun candidato');

select t.eq(
  (select count(*)::integer from public.imports_stale_uploads(interval '0 seconds')),
  3, 'con TTL zero cadono tutti tranne vivo.zip: il job running tiene in vita il suo file');

-- Il job che finisce libera il file: e' il percorso reale di ogni import riuscito.
update public.import_jobs set status = 'done'
 where storage_path = 'dddddddd-0000-0000-0000-000000000001/vivo.zip';
select t.eq(
  (select count(*)::integer from public.imports_stale_uploads(interval '0 seconds')),
  4, 'done non trattiene: appena il job chiude, il file entra nel conto del TTL');

\echo ''
\echo '=== imports_stale_uploads: chi puo'' chiamarla'

-- Su proacl, non sul revoke che si e' scritto: la lezione di `import_touched_shows`.
select t.eq(
  (select count(*)::integer from pg_proc p
     where p.proname = 'imports_stale_uploads'
       and array_to_string(p.proacl, ',') like '%anon=X%'),
  0, 'anon non puo'' eseguirla (letto da proacl)');
select t.eq(
  (select count(*)::integer from pg_proc p
     where p.proname = 'imports_stale_uploads'
       and array_to_string(p.proacl, ',') like '%authenticated=X%'),
  0, 'authenticated nemmeno: la chiama solo imports-cleanup col service key');
select t.is_true(
  (select array_to_string(p.proacl, ',') like '%service_role=X%' from pg_proc p
    where p.proname = 'imports_stale_uploads'),
  'service_role si'': e'' il chiamante del cron');

set local role authenticated;
set local request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000001';
select t.rejects(
  'select * from public.imports_stale_uploads()',
  'da authenticated l''esecuzione e'' un errore di permesso, non un elenco vuoto');
reset role;

rollback;

\echo ''
\echo 'TUTTI I TEST PASSATI'
