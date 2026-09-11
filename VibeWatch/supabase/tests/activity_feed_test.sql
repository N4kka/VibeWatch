-- Social feed M1 — `activities` (trigger e raggruppamento), `get_activity_feed` (cancelli),
-- consenso (`set_activity_feed_visibility`), autore in `get_public_lists`.
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
  ('eeeeeeee-0000-0000-0000-000000000001', 'anna@test'),   -- pubblica, consenso stampato
  ('eeeeeeee-0000-0000-0000-000000000002', 'bruno@test'),  -- pubblico, consenso stampato, segue anna
  ('eeeeeeee-0000-0000-0000-000000000003', 'carla@test'),  -- pubblica, consenso NON ancora dato
  ('eeeeeeee-0000-0000-0000-000000000004', 'dora@test');   -- per i blocchi

insert into public.profiles (id, email, display_name) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'anna@test',  'Anna'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'bruno@test', 'Bruno'),
  ('eeeeeeee-0000-0000-0000-000000000003', 'carla@test', 'Carla'),
  ('eeeeeeee-0000-0000-0000-000000000004', 'dora@test',  'Dora');

update public.profiles set username = 'anna'  where id = 'eeeeeeee-0000-0000-0000-000000000001';
update public.profiles set username = 'bruno' where id = 'eeeeeeee-0000-0000-0000-000000000002';
update public.profiles set username = 'carla' where id = 'eeeeeeee-0000-0000-0000-000000000003';
update public.profiles set username = 'dora'  where id = 'eeeeeeee-0000-0000-0000-000000000004';
update public.profiles set feed_activated_at = now()
 where id in ('eeeeeeee-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000002',
              'eeeeeeee-0000-0000-0000-000000000004');

insert into public.tmdb_shows (tmdb_show_id, name, poster_path, refreshed_at, next_refresh_at) values
  (100, 'Fringe',   '/fringe.jpg',   now(), now()),
  (200, 'The Wire', '/thewire.jpg',  now(), now());

-- bruno segue anna.
insert into public.user_follows (follower_id, followee_id) values
  ('eeeeeeee-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000001');

\echo ''
\echo '=== trigger: cio'' che non diventa mai attivita'''

insert into public.watch_events (user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at, source) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'tv', 100, 1, 1, '2026-08-01 10:00+00', 'import_tvtime');
insert into public.watch_events (user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at, watched_at_precision, source) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'tv', 100, 1, 2, '2026-08-01 11:00+00', 'inferred', 'manual');
insert into public.watch_events (user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at, source) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'tv', 100, 1, 3, '2026-08-01 12:00+00', 'bulk_show');

select t.eq((select count(*) from public.activities
              where user_id = 'eeeeeeee-0000-0000-0000-000000000001'), 0::bigint,
            'import, inferred e bulk_show non generano card');

\echo ''
\echo '=== trigger: raggruppamento episodi per giorno, id stabile'

insert into public.watch_events (id, user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at) values
  ('e1e1e1e1-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
   'tv', 100, 1, 4, '2026-08-10 10:00+00');

create temp table cap_tv as
  select id, episode_count from public.activities
   where user_id = 'eeeeeeee-0000-0000-0000-000000000001'
     and group_key = 'watch:tv:100:2026-08-10';

select t.eq((select count(*) from cap_tv), 1::bigint, 'primo episodio del giorno -> una card');
select t.eq((select episode_count from cap_tv), 1, 'con un episodio');

insert into public.watch_events (id, user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at) values
  ('e1e1e1e1-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000001',
   'tv', 100, 1, 5, '2026-08-10 11:00+00');

select t.eq((select episode_count from public.activities
              where group_key = 'watch:tv:100:2026-08-10'
                and user_id = 'eeeeeeee-0000-0000-0000-000000000001'), 2,
            'secondo episodio stesso giorno -> la card cresce');
select t.is_true((select a.id = c.id from public.activities a, cap_tv c
                   where a.user_id = 'eeeeeeee-0000-0000-0000-000000000001'
                     and a.group_key = 'watch:tv:100:2026-08-10'),
            'e l''id non cambia: like e commenti (M2) restano ancorati');
select t.eq((select occurred_at from public.activities
              where group_key = 'watch:tv:100:2026-08-10'
                and user_id = 'eeeeeeee-0000-0000-0000-000000000001'),
            '2026-08-10 11:00+00'::timestamptz, 'occurred_at = ultima visione del gruppo');
select t.eq((select title from public.activities
              where group_key = 'watch:tv:100:2026-08-10'
                and user_id = 'eeeeeeee-0000-0000-0000-000000000001'), 'Fringe',
            'snapshot del titolo dal catalogo');

\echo ''
\echo '=== trigger: il soft delete riconta, la card rivive sulla stessa riga'

update public.watch_events set deleted_at = now()
 where id = 'e1e1e1e1-0000-0000-0000-000000000002';
select t.eq((select episode_count from public.activities
              where group_key = 'watch:tv:100:2026-08-10'
                and user_id = 'eeeeeeee-0000-0000-0000-000000000001'), 1,
            'un episodio cancellato -> la card scala');

update public.watch_events set deleted_at = now()
 where id = 'e1e1e1e1-0000-0000-0000-000000000001';
select t.is_true((select deleted_at is not null from public.activities
                   where group_key = 'watch:tv:100:2026-08-10'
                     and user_id = 'eeeeeeee-0000-0000-0000-000000000001'),
            'ultimo episodio cancellato -> lapide, non DELETE');

update public.watch_events set deleted_at = null
 where id = 'e1e1e1e1-0000-0000-0000-000000000001';
select t.is_true((select a.deleted_at is null and a.id = c.id
                    from public.activities a, cap_tv c
                   where a.user_id = 'eeeeeeee-0000-0000-0000-000000000001'
                     and a.group_key = 'watch:tv:100:2026-08-10'),
            'il ripristino rianima la STESSA riga');

\echo ''
\echo '=== trigger: film, un gruppo per (film, rewatch)'

insert into public.watch_events (user_id, media_type, tmdb_movie_id, watched_at) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'movie', 555, '2026-08-09 21:00+00');
insert into public.watch_events (user_id, media_type, tmdb_movie_id, watched_at, rewatch_index) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'movie', 555, '2026-08-11 21:00+00', 1);

select t.eq((select count(*) from public.activities
              where user_id = 'eeeeeeee-0000-0000-0000-000000000001'
                and group_key like 'watch:movie:555:%'), 2::bigint,
            'prima visione e rewatch sono due card distinte');

\echo ''
\echo '=== trigger: rating e review confluiscono nella stessa card'

insert into public.user_ratings (user_id, media_type, tmdb_id, rating) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'movie', 555, 8);

create temp table cap_rated as
  select id from public.activities
   where user_id = 'eeeeeeee-0000-0000-0000-000000000001'
     and group_key = 'rated:movie:555';

select t.eq((select count(*) from cap_rated), 1::bigint, 'il voto fa la card');

insert into public.user_reviews (id, user_id, media_type, tmdb_id, content) values
  ('feedfeed-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
   'movie', 555, 'Mezzo capolavoro.');

select t.is_true((select a.review_id = 'feedfeed-0000-0000-0000-000000000001'
                     and a.rating = 8 and a.id = c.id
                    from public.activities a, cap_rated c
                   where a.group_key = 'rated:movie:555'
                     and a.user_id = 'eeeeeeee-0000-0000-0000-000000000001'),
            'la review atterra sulla card del voto, stessa riga');

select t.rejects(
  $q$insert into public.user_reviews (id, user_id, media_type, tmdb_id, content) values
     ('feedfeed-0000-0000-0000-000000000099', 'eeeeeeee-0000-0000-0000-000000000001',
      'movie', 555, 'doppione')$q$,
  'una seconda review viva per lo stesso titolo non puo'' esistere');

update public.user_ratings set deleted_at = now()
 where user_id = 'eeeeeeee-0000-0000-0000-000000000001' and media_type = 'movie' and tmdb_id = 555;
select t.is_true((select a.deleted_at is null and a.rating is null
                    from public.activities a
                   where a.group_key = 'rated:movie:555'
                     and a.user_id = 'eeeeeeee-0000-0000-0000-000000000001'),
            'voto tolto ma review viva -> la card resta, senza stelle');

update public.user_reviews set deleted_at = now()
 where id = 'feedfeed-0000-0000-0000-000000000001';
select t.is_true((select deleted_at is not null from public.activities
                   where group_key = 'rated:movie:555'
                     and user_id = 'eeeeeeee-0000-0000-0000-000000000001'),
            'anche la review tolta -> lapide');

-- Lo stato che il feed vedra'' dopo: voto+review vivi su un altro film.
insert into public.user_ratings (user_id, media_type, tmdb_id, rating) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'movie', 777, 9);
insert into public.user_reviews (id, user_id, media_type, tmdb_id, content, contains_spoilers) values
  ('feedfeed-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000001',
   'movie', 777, 'Da vedere due volte.', false);

\echo ''
\echo '=== trigger: liste pubbliche'

insert into public.lists (id, user_id, name, type, is_public) values
  ('11111111-aaaa-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
   'Fantascienza anni 90', 'custom', true);

create temp table cap_list as
  select id from public.activities
   where user_id = 'eeeeeeee-0000-0000-0000-000000000001'
     and group_key = 'list:11111111-aaaa-0000-0000-000000000001';

select t.eq((select count(*) from cap_list), 1::bigint, 'lista pubblica -> card');

update public.lists set is_public = false
 where id = '11111111-aaaa-0000-0000-000000000001';
select t.is_true((select deleted_at is not null from public.activities
                   where group_key = 'list:11111111-aaaa-0000-0000-000000000001'),
            'lista tornata privata -> lapide');

update public.lists set is_public = true
 where id = '11111111-aaaa-0000-0000-000000000001';
select t.is_true((select a.deleted_at is null and a.id = c.id
                    from public.activities a, cap_list c
                   where a.group_key = 'list:11111111-aaaa-0000-0000-000000000001'),
            'ri-pubblicata -> stessa riga, la card non risale il feed');

\echo ''
\echo '=== trigger: serie completata, col cancello anti-import'

-- Il ricalcolo (trigger di watch_events) ha gia'' creato la riga di stato per (anna, 100).
update public.tv_show_state set completed_at = '2026-08-11 22:00+00'
 where user_id = 'eeeeeeee-0000-0000-0000-000000000001' and tmdb_show_id = 100;

select t.eq((select count(*) from public.activities
              where user_id = 'eeeeeeee-0000-0000-0000-000000000001'
                and group_key = 'completed:tv:100'
                and deleted_at is null), 1::bigint,
            'serie con eventi manuali vivi -> card "ha finito"');

-- bruno ha The Wire SOLO da import: il completed_at che ne deriva non fa card.
insert into public.watch_events (user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at, source) values
  ('eeeeeeee-0000-0000-0000-000000000002', 'tv', 200, 1, 1, '2024-05-01 20:00+00', 'import_tvtime');
update public.tv_show_state set completed_at = now()
 where user_id = 'eeeeeeee-0000-0000-0000-000000000002' and tmdb_show_id = 200;

select t.eq((select count(*) from public.activities
              where user_id = 'eeeeeeee-0000-0000-0000-000000000002'
                and group_key = 'completed:tv:200'), 0::bigint,
            'serie arrivata intera da import -> nessuna card');

-- Poi bruno guarda un episodio DAVVERO: il cancello si alza al completamento successivo.
-- (Il timestamp e'' esplicito: il ricalcolo scatenato dall''evento manuale ha appena azzerato
-- completed_at, e un bump relativo su null resterebbe null senza far scattare il trigger.)
insert into public.watch_events (user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at) values
  ('eeeeeeee-0000-0000-0000-000000000002', 'tv', 200, 1, 2, '2026-08-11 21:00+00');
update public.tv_show_state set completed_at = '2026-08-11 21:05+00'
 where user_id = 'eeeeeeee-0000-0000-0000-000000000002' and tmdb_show_id = 200;

select t.eq((select count(*) from public.activities
              where user_id = 'eeeeeeee-0000-0000-0000-000000000002'
                and group_key = 'completed:tv:200'
                and deleted_at is null), 1::bigint,
            'con almeno un evento vero la card nasce');

\echo ''
\echo '=== get_activity_feed: scope e cancello dell''autore'

-- carla (consenso mai dato) ha attivita'': non deve vedersi in giro.
insert into public.watch_events (user_id, media_type, tmdb_movie_id, watched_at) values
  ('eeeeeeee-0000-0000-0000-000000000003', 'movie', 888, '2026-08-11 20:00+00');
-- dora pure, servira'' per i blocchi.
insert into public.watch_events (user_id, media_type, tmdb_movie_id, watched_at) values
  ('eeeeeeee-0000-0000-0000-000000000004', 'movie', 999, '2026-08-11 19:00+00');

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';

select t.is_true(exists(select 1 from public.get_activity_feed('following', null, null, null, 50) f
                         where f.user_id = 'eeeeeeee-0000-0000-0000-000000000001'),
            'following: le card di chi seguo ci sono');
select t.is_true(exists(select 1 from public.get_activity_feed('following', null, null, null, 50) f
                         where f.user_id = 'eeeeeeee-0000-0000-0000-000000000002'),
            'following: anche le mie — la conferma che il feed funziona');
select t.is_true(not exists(select 1 from public.get_activity_feed('following', null, null, null, 50) f
                             where f.user_id = 'eeeeeeee-0000-0000-0000-000000000003'),
            'following: chi non seguo no');
select t.is_true(not exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                             where f.user_id = 'eeeeeeee-0000-0000-0000-000000000003'),
            'community: chi non ha mai risposto all''annuncio e'' invisibile, backfill compreso');
select t.eq((select f.review_content from public.get_activity_feed('following', null, null, null, 50) f
              where f.user_id = 'eeeeeeee-0000-0000-0000-000000000001'
                and f.activity_type = 'rated' and f.tmdb_id = 777),
            'Da vedere due volte.', 'la review viaggia nella card');
select t.eq((select f.username from public.get_activity_feed('following', null, null, null, 50) f
              where f.activity_type = 'rated' and f.tmdb_id = 777),
            'anna', 'con l''identita'' dell''autore');

\echo ''
\echo '=== consenso: la RPC stampa una volta sola'

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000003';
select public.set_activity_feed_visibility(true);

create temp table cap_consent as
  select feed_activated_at from public.profiles
   where id = 'eeeeeeee-0000-0000-0000-000000000003';
select t.is_true((select feed_activated_at is not null from public.profiles
                   where id = 'eeeeeeee-0000-0000-0000-000000000003'),
            'la risposta stampa feed_activated_at');

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';
select t.is_true(exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                         where f.user_id = 'eeeeeeee-0000-0000-0000-000000000003'),
            'e da quel momento la community la vede');

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000003';
select public.set_activity_feed_visibility(false);
select t.is_true((select p.feed_activated_at = c.feed_activated_at
                    from public.profiles p, cap_consent c
                   where p.id = 'eeeeeeee-0000-0000-0000-000000000003'),
            'il timestamp del consenso non si riscrive mai');

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';
select t.is_true(not exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                             where f.user_id = 'eeeeeeee-0000-0000-0000-000000000003'),
            'feed spento -> di nuovo invisibile');

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000003';
select t.is_true(exists(select 1 from public.get_activity_feed('user',
                          'eeeeeeee-0000-0000-0000-000000000003', null, null, 50) f
                         where f.user_id = 'eeeeeeee-0000-0000-0000-000000000003'),
            'ma a se stessi si e'' sempre visibili');

\echo ''
\echo '=== profilo privato e blocchi'

update public.profiles set is_profile_public = false
 where id = 'eeeeeeee-0000-0000-0000-000000000001';
set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';
select t.is_true(not exists(select 1 from public.get_activity_feed('following', null, null, null, 50) f
                             where f.user_id = 'eeeeeeee-0000-0000-0000-000000000001'),
            'profilo privato -> le card spariscono anche dai follower');
update public.profiles set is_profile_public = true
 where id = 'eeeeeeee-0000-0000-0000-000000000001';

select t.is_true(exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                         where f.user_id = 'eeeeeeee-0000-0000-0000-000000000004'),
            'prima del blocco, bruno vede dora');
insert into public.user_blocks (user_id, blocked_user_id) values
  ('eeeeeeee-0000-0000-0000-000000000004', 'eeeeeeee-0000-0000-0000-000000000002');
select t.is_true(not exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                             where f.user_id = 'eeeeeeee-0000-0000-0000-000000000004'),
            'dora blocca bruno -> bruno non vede dora (il verso invisibile all''invoker)');
set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000004';
select t.is_true(not exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                             where f.user_id = 'eeeeeeee-0000-0000-0000-000000000002'),
            'e dora non vede bruno: il blocco taglia nei due versi');

\echo ''
\echo '=== la card lista e i report'

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';
select t.is_true(exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                         where f.activity_type = 'list_created'
                           and f.list_id = '11111111-aaaa-0000-0000-000000000001'),
            'la card lista c''e'', prima dei report');
select t.eq((select f.list_name from public.get_activity_feed('community', null, null, null, 50) f
              where f.list_id = '11111111-aaaa-0000-0000-000000000001'),
            'Fantascienza anni 90', 'col nome vivo della lista');

insert into public.list_reports (user_id, list_id, reason) values
  ('eeeeeeee-0000-0000-0000-000000000002', '11111111-aaaa-0000-0000-000000000001', 'spam'),
  ('eeeeeeee-0000-0000-0000-000000000003', '11111111-aaaa-0000-0000-000000000001', 'spam'),
  ('eeeeeeee-0000-0000-0000-000000000004', '11111111-aaaa-0000-0000-000000000001', 'spam');

select t.is_true(not exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                             where f.list_id = '11111111-aaaa-0000-0000-000000000001'),
            '3 segnalatori distinti -> la card sparisce dal feed, come dal tab Liste');
set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000001';
select t.is_true(exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                         where f.list_id = '11111111-aaaa-0000-0000-000000000001'),
            'ma il proprietario la vede ancora, stessa eccezione di get_public_lists');

\echo ''
\echo '=== keyset: pagine senza doppioni'

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';

create temp table feed_all as
  select f.activity_id, f.occurred_at, row_number() over () as rn
    from public.get_activity_feed('community', null, null, null, 50) f;

create temp table feed_p1 as
  select f.activity_id, f.occurred_at
    from public.get_activity_feed('community', null, null, null, 2) f;

select t.eq((select count(*) from feed_p1), 2::bigint, 'pagina 1: due card');
select t.is_true((select bool_and(p.activity_id = a.activity_id)
                    from feed_p1 p
                    join feed_all a on a.rn = (select count(*) from feed_p1 q
                                                where q.occurred_at > p.occurred_at
                                                   or (q.occurred_at = p.occurred_at
                                                       and q.activity_id >= p.activity_id))),
            'pagina 1 = testa della lista completa');

create temp table feed_p2 as
  select f.activity_id
    from public.get_activity_feed('community', null,
           (select occurred_at from feed_all where rn = 2),
           (select activity_id from feed_all where rn = 2), 2) f;

select t.is_true(not exists(select 1 from feed_p2 where activity_id in
                             (select activity_id from feed_p1)),
            'pagina 2 dal cursore: nessun doppione');
select t.eq((select activity_id from feed_p2 limit 1),
            (select activity_id from feed_all where rn = 3),
            'e riparte esattamente dalla card successiva');

\echo ''
\echo '=== M3: rimuovi dal feed (hidden_at) e card per id'

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000001';

create temp table cap_hidden as
  select id from public.activities
   where user_id = 'eeeeeeee-0000-0000-0000-000000000001'
     and group_key = 'watch:tv:100:2026-08-10';

select t.is_true(exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                         where f.activity_id = (select id from cap_hidden)),
            'prima di nasconderla la card c''e''');

select t.is_true(public.hide_activity((select id from cap_hidden)),
            'hide_activity sulla propria card risponde true');
select t.is_true(not exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                             where f.activity_id = (select id from cap_hidden)),
            'e sparisce dal feed, anche a chi l''ha nascosta');
select t.is_true(not exists(select 1 from public.get_activity_feed('user',
                              'eeeeeeee-0000-0000-0000-000000000001', null, null, 50) f
                             where f.activity_id = (select id from cap_hidden)),
            'nemmeno nell''attivita'' del proprio profilo');

select t.is_true(public.hide_activity((select id from cap_hidden)),
            'idempotente: la seconda chiamata risponde ancora true');

-- Il motivo per cui hidden_at non e'' deleted_at: un altro episodio quel giorno fa ripartire
-- l''upsert del trigger, che azzera deleted_at. Se la rimozione vivesse li'', la card tornerebbe.
create temp table cap_hidden_at as
  select hidden_at from public.activities where id = (select id from cap_hidden);

insert into public.watch_events (user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'tv', 100, 1, 6, '2026-08-10 15:00+00');

select t.is_true((select a.deleted_at is null and a.hidden_at = c.hidden_at
                    from public.activities a, cap_hidden_at c
                   where a.id = (select id from cap_hidden)),
            'il ricalcolo riscrive la riga ma non tocca hidden_at');
select t.is_true(not exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                             where f.activity_id = (select id from cap_hidden)),
            'e la card resta fuori dal feed dopo il ricalcolo');

-- Una card altrui non si nasconde, e la risposta non distingue "non e'' tua" da "non esiste".
create temp table cap_anna_rated as
  select id from public.activities
   where user_id = 'eeeeeeee-0000-0000-0000-000000000001'
     and group_key = 'rated:movie:777';

set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';
select t.is_true(not public.hide_activity((select id from cap_anna_rated)),
            'hide_activity su una card altrui risponde false');
select t.is_true(not public.hide_activity('cafe0000-0000-0000-0000-000000000000'),
            'e su una card inesistente risponde lo stesso false');
select t.is_true(exists(select 1 from public.get_activity_feed('community', null, null, null, 50) f
                         where f.activity_id = (select id from cap_anna_rated)),
            'la card altrui e'' ancora li''');

-- p_activity_id: la card del deep link salta scope e cursore, non il cancello.
set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000003';
select t.eq((select count(*) from public.get_activity_feed('following', null, null, null, 20,
                                                           (select id from cap_anna_rated))),
            1::bigint,
            'per id si apre anche la card di chi non seguo');
select t.is_true(not exists(select 1 from public.get_activity_feed('following', null, null, null, 20,
                                                                   (select id from cap_hidden))),
            'ma non una nascosta');

-- carla ha il feed spento (sezione consenso): la sua card per id non si apre a nessun altro.
set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';
select t.is_true(not exists(select 1 from public.get_activity_feed('community', null, null, null, 20,
                             (select id from public.activities
                               where user_id = 'eeeeeeee-0000-0000-0000-000000000003'
                                 and group_key = 'watch:movie:888:0'))),
            'e il cancello dell''autore vale anche sulla card per id');

\echo ''
\echo '=== get_public_lists: l''autore'

-- La lista di anna e'' nascosta dai report per gli altri: la si guarda da proprietaria.
set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000001';
select t.eq((select l.owner_username from public.get_public_lists(null, 'explore', 50, 0, null) l
              where l.id = '11111111-aaaa-0000-0000-000000000001'),
            'anna', 'la lista pubblica dichiara il suo autore');

update public.profiles set is_profile_public = false
 where id = 'eeeeeeee-0000-0000-0000-000000000001';
select t.is_true((select l.owner_username is null
                    from public.get_public_lists(null, 'explore', 50, 0, null) l
                   where l.id = '11111111-aaaa-0000-0000-000000000001'),
            'profilo privato -> la lista resta, l''autore no (contratto di public_profiles)');
update public.profiles set is_profile_public = true
 where id = 'eeeeeeee-0000-0000-0000-000000000001';

\echo ''
\echo '=== grant: authenticated passa, anon no'

set local role authenticated;
set local request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';
select t.is_true((select count(*) >= 0 from public.get_activity_feed('community', null, null, null, 5)),
            'authenticated esegue la RPC del feed');
select public.set_activity_feed_visibility(true);
reset role;

set local role anon;
select t.rejects('select * from public.get_activity_feed(''community'', null, null, null, 5)',
            'anon non esegue la RPC del feed');
select t.rejects('select public.set_activity_feed_visibility(true)',
            'ne'' quella del consenso');
reset role;

rollback;
