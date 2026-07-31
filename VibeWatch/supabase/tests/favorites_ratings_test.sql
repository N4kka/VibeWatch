-- Blocco 9 di §12 — `user_favorites` e `user_ratings` (§3.6, §9.3).
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
  ('bbbbbbbb-0000-0000-0000-000000000001', 'fa@test'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'fb@test');

\echo ''
\echo '=== §3.6 user_favorites: 4+4 slot, la forma'

set local role authenticated;
set local request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';

-- 4 slot film + 4 slot serie: il massimo previsto, tutto legittimo.
insert into public.user_favorites (user_id, media_type, slot, tmdb_id)
select 'bbbbbbbb-0000-0000-0000-000000000001', m, s, 100 * s
from (values ('movie'), ('tv')) as mt(m), generate_series(1, 4) as s;

select t.eq((select count(*)::integer from public.user_favorites), 8,
            '4 film + 4 serie entrano tutti');

select t.rejects(
  $$insert into public.user_favorites (user_id, media_type, slot, tmdb_id)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 5, 500)$$,
  'lo slot 5 non esiste: sono 4, non "circa 4"');

select t.rejects(
  $$insert into public.user_favorites (user_id, media_type, slot, tmdb_id)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 0, 500)$$,
  'e nemmeno lo slot 0');

select t.rejects(
  $$insert into public.user_favorites (user_id, media_type, slot, tmdb_id)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'episode', 1, 500)$$,
  'un favorite e'' un film o una serie, non un episodio');

select t.rejects(
  $$insert into public.user_favorites (user_id, media_type, slot, tmdb_id)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 1, 999)$$,
  'lo stesso slot due volte e'' un conflitto di PK, non una seconda riga');

-- Svuotare uno slot e' una lapide, non una DELETE: la riga resta e il pull la porta in giro.
update public.user_favorites set deleted_at = now(), updated_at = now()
 where media_type = 'movie' and slot = 1;
select t.eq((select count(*)::integer from public.user_favorites
              where media_type = 'movie' and slot = 1 and deleted_at is not null), 1,
            'lo slot svuotato resta come lapide');

-- Rimetterci un film e' un update sulla stessa riga (PK = lo slot): la lapide si toglie.
update public.user_favorites set tmdb_id = 42, deleted_at = null, updated_at = now()
 where media_type = 'movie' and slot = 1;
select t.eq((select tmdb_id from public.user_favorites
              where media_type = 'movie' and slot = 1 and deleted_at is null), 42,
            'riempire di nuovo lo slot riusa la riga');

\echo ''
\echo '=== §3.6 user_favorites: RLS, i favorites altrui non esistono'

set local request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';

select t.eq((select count(*)::integer from public.user_favorites), 0,
            'b non vede i favorites di a');

select t.rejects(
  $$insert into public.user_favorites (user_id, media_type, slot, tmdb_id)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 2, 666)$$,
  'b non scrive negli slot di a');

-- Un update su righe che la RLS nasconde tocca 0 righe, in silenzio: la prova e' il valore intatto.
update public.user_favorites set tmdb_id = 666
 where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_type = 'movie' and slot = 1;
set local request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
select t.eq((select tmdb_id from public.user_favorites
              where media_type = 'movie' and slot = 1), 42,
            'e l''update di b su a non ha toccato niente');

\echo ''
\echo '=== §3.6 user_ratings: mezze stelle intere, la forma'

insert into public.user_ratings (user_id, media_type, tmdb_id, rating)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 603, 7);
select t.eq((select rating::integer from public.user_ratings
              where media_type = 'movie' and tmdb_id = 603), 7,
            'un voto a un film entra, e si rilegge');

select t.rejects(
  $$insert into public.user_ratings (user_id, media_type, tmdb_id, rating)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 604, 0)$$,
  'zero stelle non e'' un voto: il minimo e'' mezza (1)');

select t.rejects(
  $$insert into public.user_ratings (user_id, media_type, tmdb_id, rating)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 604, 11)$$,
  'e il massimo e'' 10, cioe'' 5 stelle');

select t.rejects(
  $$insert into public.user_ratings (user_id, media_type, tmdb_id, rating)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'episode', 1399, 8)$$,
  'un voto a un episodio senza numeri di episodio non e'' un dato');

select t.rejects(
  $$insert into public.user_ratings (user_id, media_type, tmdb_id, season_number, episode_number, rating)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 603, 1, 1, 8)$$,
  'e un film con una stagione nemmeno');

select t.rejects(
  $$insert into public.user_ratings (user_id, media_type, tmdb_id, rating)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 603, 9)$$,
  'due voti vivi sulla stessa chiave sono un conflitto, non una seconda riga');

-- Lo stesso tmdb_id con media_type diverso e' un'altra chiave: 603 la serie non e' 603 il film.
insert into public.user_ratings (user_id, media_type, tmdb_id, rating)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'tv', 603, 6);

-- Episodi distinti della stessa serie: chiavi distinte.
insert into public.user_ratings (user_id, media_type, tmdb_id, season_number, episode_number, rating)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'episode', 1399, 1, 1, 10),
       ('bbbbbbbb-0000-0000-0000-000000000001', 'episode', 1399, 1, 2, 9);

select t.rejects(
  $$insert into public.user_ratings (user_id, media_type, tmdb_id, season_number, episode_number, rating)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'episode', 1399, 1, 1, 2)$$,
  'lo stesso episodio due volte no: l''indice unico vale anche con la stagione nella chiave');

select t.eq((select count(*)::integer from public.user_ratings), 4,
            'film + serie + due episodi: quattro voti vivi');

-- L'indice e' parziale apposta (§3.6): dopo una lapide, una nuova riga viva puo' nascere.
-- Che il re-voto RIUSI la riga invece di crearne una seconda e' compito del ramo in
-- apply_mutations, non dell'indice — qui si fissa solo cio' che l'indice garantisce: mai
-- due righe vive.
update public.user_ratings set deleted_at = now()
 where media_type = 'movie' and tmdb_id = 603;
insert into public.user_ratings (user_id, media_type, tmdb_id, rating)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 603, 3);
select t.eq((select count(*)::integer from public.user_ratings
              where media_type = 'movie' and tmdb_id = 603 and deleted_at is null), 1,
            'dopo la lapide un voto nuovo entra, e di vivo ce n''e'' sempre uno solo');

\echo ''
\echo '=== §3.6 user_ratings: RLS'

set local request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';

select t.eq((select count(*)::integer from public.user_ratings), 0,
            'b non vede i voti di a');

select t.rejects(
  $$insert into public.user_ratings (user_id, media_type, tmdb_id, rating)
    values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 777, 5)$$,
  'b non vota a nome di a');

reset role;

\echo ''
\echo '=== Chi puo'' fare cosa: i grant, non solo la RLS'

select t.eq(has_table_privilege('anon', 'public.user_favorites', 'select'), false,
            'user_favorites non ha grant per anon, prima ancora della RLS');
select t.eq(has_table_privilege('anon', 'public.user_ratings', 'select'), false,
            'idem user_ratings');
select t.eq(has_table_privilege('authenticated', 'public.user_favorites', 'delete'), false,
            'il client non ha la DELETE fisica sui favorites: si svuota con la lapide');
select t.eq(has_table_privilege('authenticated', 'public.user_ratings', 'delete'), false,
            'ne'' sui voti: si toglie un voto con la lapide');
select t.is_true(has_table_privilege('authenticated', 'public.user_favorites', 'select')
             and has_table_privilege('authenticated', 'public.user_favorites', 'insert')
             and has_table_privilege('authenticated', 'public.user_favorites', 'update'),
            'ma legge e scrive i propri favorites');
select t.is_true(has_table_privilege('authenticated', 'public.user_ratings', 'select')
             and has_table_privilege('authenticated', 'public.user_ratings', 'insert')
             and has_table_privilege('authenticated', 'public.user_ratings', 'update'),
            'e i propri voti');

\echo ''
\echo '=== §9.3/§13.7 get_my_stats: runtime reali, mai stime'

-- Catalogo minimo: un episodio con runtime per il ripiego quando lo snapshot manca.
insert into public.tmdb_shows (tmdb_show_id, name) values (900, 'Stats Show');
insert into public.tmdb_episodes (tmdb_show_id, season_number, episode_number, tmdb_episode_id, runtime_minutes)
values (900, 1, 3, 9003, 40);

insert into public.watch_events (user_id, media_type, tmdb_show_id, season_number, episode_number,
                                 watched_at, runtime_seconds, rewatch_index, deleted_at)
values
  -- due episodi con lo snapshot
  ('bbbbbbbb-0000-0000-0000-000000000001', 'tv', 900, 1, 1, now(), 1500, 0, null),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'tv', 900, 1, 2, now(), 1500, 0, null),
  -- snapshot mancante: il runtime arriva dal catalogo (40 min = 2400 s)
  ('bbbbbbbb-0000-0000-0000-000000000001', 'tv', 900, 1, 3, now(), null, 0, null),
  -- un rewatch: tempo vero in piu', ma NON un episodio in piu'
  ('bbbbbbbb-0000-0000-0000-000000000001', 'tv', 900, 1, 1, now(), 1500, 1, null),
  -- un evento cancellato non conta niente
  ('bbbbbbbb-0000-0000-0000-000000000001', 'tv', 900, 1, 4, now(), 9999, 0, now());
insert into public.watch_events (user_id, media_type, tmdb_movie_id, watched_at, runtime_seconds)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'movie', 603, now(), 7200);

set local role authenticated;
set local request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';

select t.eq(((public.get_my_stats())->>'watch_time_seconds')::bigint, 14100::bigint,
            '1500+1500+2400(catalogo)+1500(rewatch)+7200(film), il cancellato fuori');
select t.eq(((public.get_my_stats())->>'episodes_watched')::integer, 3,
            'il rewatch non e'' un episodio in piu''');
select t.eq(((public.get_my_stats())->>'shows_watched')::integer, 1, 'una serie');
select t.eq(((public.get_my_stats())->>'movies_watched')::integer, 1, 'un film');
select t.eq(((public.get_my_stats())->>'ratings_given')::integer, 4,
            'i voti vivi di prima, la lapide esclusa');

set local request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
select t.eq(((public.get_my_stats())->>'watch_time_seconds')::bigint, 0::bigint,
            'le stats sono del chiamante: b non eredita niente da a');
select t.eq(((public.get_my_stats())->>'episodes_watched')::integer, 0, 'zeri, non errori');

reset role;

\echo ''
\echo '=== §9.3 i favorites nel profilo pubblico'

insert into public.profiles (id, email, display_name, username, is_profile_public)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'fa@test', 'Fav User', 'fav_user', true);

set local role authenticated;
set local request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';

-- Lo stato dei favorites film di a, costruito nelle sezioni sopra: slot 1 svuotato e
-- ririempito con 42, gli altri come alla nascita.
select t.eq(jsonb_array_length((public.get_public_profile('fav_user'))->'favorites'->'movie'), 4,
            'quattro slot film vivi');
select t.eq(((public.get_public_profile('fav_user'))->'favorites'->'movie'->0->>'tmdb_id')::integer, 42,
            'lo slot 1 mostra il film ririempito, non la lapide');
select t.eq(jsonb_array_length((public.get_public_profile('fav_user'))->'favorites'->'tv'), 4,
            'e quattro slot serie');

-- Uno slot svuotato sparisce dal profilo pubblico.
reset role;
update public.user_favorites set deleted_at = now()
 where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_type = 'movie' and slot = 2;
set local role authenticated;
set local request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
select t.eq(jsonb_array_length((public.get_public_profile('fav_user'))->'favorites'->'movie'), 3,
            'lo slot svuotato non si mostra');

reset role;

select t.eq((select count(*)::integer from pg_proc p
              where p.proname = 'get_my_stats'
                and array_to_string(p.proacl, ',') like '%anon=X%'), 0,
            'get_my_stats non e'' chiamabile da anon');
select t.is_true((select array_to_string(p.proacl, ',') like '%authenticated=X%'
                    from pg_proc p where p.proname = 'get_my_stats'),
            'ma lo e'' da authenticated');

rollback;

\echo ''
\echo 'TUTTI I TEST PASSATI'
