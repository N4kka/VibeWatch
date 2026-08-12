-- SPEC v3 §1.5/§6 — la cache TVDB→TMDB e' condivisa e un'identita' `found` e' finale.

\set ON_ERROR_STOP on
\set QUIET 1
\pset pager off
\pset tuples_only on
\pset footer off

begin;
set local timezone = 'UTC';

insert into public.tvdb_tmdb_map
  (tvdb_id, entity_type, tmdb_show_id, season_number, episode_number,
   resolution, method, resolved_at)
values
  (7001, 'episode', 111, 1, 1, 'found', 'tmdb_find', now()),
  (7002, 'episode', null, null, null, 'not_found', 'tmdb_find', now());

\echo ''
\echo '=== catalog_store_tvdb_map: found immutabile'

set local role service_role;
select t.eq(
  (select (row->>'tmdb_show_id')::integer
     from jsonb_array_elements(public.catalog_store_tvdb_map('[
       {"tvdb_id":7001,"entity_type":"episode","tmdb_show_id":222,
        "tmdb_movie_id":null,"season_number":9,"episode_number":9,
        "resolution":"found","method":"tmdb_find_manual","resolved_at":"2026-08-02T00:00:00Z"},
       {"tvdb_id":7002,"entity_type":"episode","tmdb_show_id":333,
        "tmdb_movie_id":null,"season_number":2,"episode_number":3,
        "resolution":"found","method":"tmdb_find_manual","resolved_at":"2026-08-02T00:00:00Z"}
     ]'::jsonb)) as row
    where row->>'tvdb_id' = '7001'),
  111, 'la risposta restituisce la riga found che ha vinto, non il tentativo concorrente');
reset role;

select t.eq(
  (select tmdb_show_id::text || '/' || season_number::text || '/' || episode_number::text
     from public.tvdb_tmdb_map where tvdb_id = 7001 and entity_type = 'episode'),
  '111/1/1', 'un found preesistente non viene mai sovrascritto');
select t.eq(
  (select resolution || '/' || tmdb_show_id::text || '/' || season_number::text || '/'
          || episode_number::text
     from public.tvdb_tmdb_map where tvdb_id = 7002 and entity_type = 'episode'),
  'found/333/2/3', 'una riga non finale puo'' invece diventare found');

\echo ''
\echo '=== catalog_store_tvdb_map: grant minimo'

select t.is_true(not has_function_privilege(
  'authenticated', 'public.catalog_store_tvdb_map(jsonb)', 'execute'),
  'il client non puo'' scrivere la cache condivisa');
select t.is_true(has_function_privilege(
  'service_role', 'public.catalog_store_tvdb_map(jsonb)', 'execute'),
  'catalog-resolve col service role puo'' applicare il batch');

rollback;
