-- Audit GDPR §3b — la meta SQL di delete-user: inventario completo degli oggetti Storage
-- dell'utente, senza esporre l'inventario ai ruoli client.

\set ON_ERROR_STOP on
\set QUIET 1
\pset pager off
\pset tuples_only on
\pset footer off

begin;

insert into auth.users (id, email) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'delete-a@test'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'delete-b@test');

-- Tre oggetti devono appartenere all'inventario di A:
-- 1. owner A in avatars;
-- 2. owner A in un bucket futuro, perché GDPR non dipende dall'elenco noto oggi;
-- 3. path imports/A anche con owner incoerente, perché la cartella è il contratto del bucket.
-- L'avatar e lo ZIP di B non devono mai comparire.
insert into storage.objects (bucket_id, name, owner) values
  ('avatars', 'device-a/avatar.jpg', 'eeeeeeee-0000-0000-0000-000000000001'),
  ('future-user-files', 'opaque.bin', 'eeeeeeee-0000-0000-0000-000000000001'),
  ('imports', 'eeeeeeee-0000-0000-0000-000000000001/export.zip',
   'eeeeeeee-0000-0000-0000-000000000002'),
  ('avatars', 'device-b/avatar.jpg', 'eeeeeeee-0000-0000-0000-000000000002'),
  ('imports', 'eeeeeeee-0000-0000-0000-000000000002/export.zip',
   'eeeeeeee-0000-0000-0000-000000000002');

\echo ''
\echo '=== user_storage_objects: inventario'

select t.eq(
  (select count(*)::integer
     from public.user_storage_objects('eeeeeeee-0000-0000-0000-000000000001')),
  3, 'A vede tutti e soli i propri oggetti, compreso il path imports con owner incoerente');

select t.eq(
  (select string_agg(bucket_id || ':' || name, ',' order by bucket_id, name)
     from public.user_storage_objects('eeeeeeee-0000-0000-0000-000000000001')),
  'avatars:device-a/avatar.jpg,future-user-files:opaque.bin,imports:eeeeeeee-0000-0000-0000-000000000001/export.zip',
  'l''inventario non è limitato ai bucket conosciuti oggi e non include oggetti di B');

\echo ''
\echo '=== user_storage_objects: privilegi'

select t.eq(
  (select count(*)::integer from pg_proc p
    where p.proname = 'user_storage_objects'
      and array_to_string(p.proacl, ',') like '%anon=X%'),
  0, 'anon non può inventariare i file altrui');

select t.eq(
  (select count(*)::integer from pg_proc p
    where p.proname = 'user_storage_objects'
      and array_to_string(p.proacl, ',') like '%authenticated=X%'),
  0, 'authenticated non può chiamare la funzione definer');

select t.is_true(
  (select array_to_string(p.proacl, ',') like '%service_role=X%'
     from pg_proc p where p.proname = 'user_storage_objects'),
  'service_role può inventariare prima che delete-user chiami la Storage API');

set local role authenticated;
set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000001';
select t.rejects(
  $$select * from public.user_storage_objects('eeeeeeee-0000-0000-0000-000000000002')$$,
  'authenticated riceve permission denied, non l''inventario di B');
reset role;

rollback;

\echo ''
\echo 'TUTTI I TEST PASSATI'
