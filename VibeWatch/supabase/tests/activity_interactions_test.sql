-- Social feed M2 — like e commenti (gate, toggle, thread), moderazione (report, block_user,
-- potatura follow), conteggi veri e velo report in get_activity_feed, notifiche con dedupe.
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
  ('ffffffff-0000-0000-0000-000000000001', 'anna@t'),    -- autrice della card
  ('ffffffff-0000-0000-0000-000000000002', 'bruno@t'),   -- interagisce
  ('ffffffff-0000-0000-0000-000000000003', 'carla@t'),   -- blocca bruno
  ('ffffffff-0000-0000-0000-000000000004', 'dora@t'),    -- terza segnalatrice
  ('ffffffff-0000-0000-0000-000000000005', 'emma@t');    -- consenso mai dato

insert into public.profiles (id, email, display_name) values
  ('ffffffff-0000-0000-0000-000000000001', 'anna@t',  'Anna'),
  ('ffffffff-0000-0000-0000-000000000002', 'bruno@t', 'Bruno'),
  ('ffffffff-0000-0000-0000-000000000003', 'carla@t', 'Carla'),
  ('ffffffff-0000-0000-0000-000000000004', 'dora@t',  'Dora'),
  ('ffffffff-0000-0000-0000-000000000005', 'emma@t',  'Emma');

update public.profiles set username = 'anna2'  where id = 'ffffffff-0000-0000-0000-000000000001';
update public.profiles set username = 'bruno2' where id = 'ffffffff-0000-0000-0000-000000000002';
update public.profiles set username = 'carla2' where id = 'ffffffff-0000-0000-0000-000000000003';
update public.profiles set username = 'dora2'  where id = 'ffffffff-0000-0000-0000-000000000004';
update public.profiles set username = 'emma2'  where id = 'ffffffff-0000-0000-0000-000000000005';
update public.profiles set feed_activated_at = now()
 where id in ('ffffffff-0000-0000-0000-000000000001',
              'ffffffff-0000-0000-0000-000000000002',
              'ffffffff-0000-0000-0000-000000000003',
              'ffffffff-0000-0000-0000-000000000004');

-- Le card: un voto di anna, uno di carla, uno di emma (che non ha mai consentito).
insert into public.user_ratings (user_id, media_type, tmdb_id, rating) values
  ('ffffffff-0000-0000-0000-000000000001', 'movie', 42, 9),
  ('ffffffff-0000-0000-0000-000000000003', 'movie', 77, 7),
  ('ffffffff-0000-0000-0000-000000000005', 'movie', 88, 6);

create temp table act as
  select
    (select id from public.activities where user_id = 'ffffffff-0000-0000-0000-000000000001'
      and group_key = 'rated:movie:42') as anna,
    (select id from public.activities where user_id = 'ffffffff-0000-0000-0000-000000000003'
      and group_key = 'rated:movie:77') as carla,
    (select id from public.activities where user_id = 'ffffffff-0000-0000-0000-000000000005'
      and group_key = 'rated:movie:88') as emma;

-- Il blocco dei grant in fondo legge questa temp table impersonando i ruoli client.
grant select on act to authenticated, anon;

\echo ''
\echo '=== like: toggle, lapide, resurrezione sulla stessa riga'

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';

select t.eq((select liked from public.toggle_activity_like((select anna from act),
            'aaaa1111-0000-0000-0000-000000000001')), true, 'primo like -> liked');
select t.eq((select like_count from public.toggle_activity_like((select anna from act))), 0,
            'secondo toggle -> unlike, contatore a zero');
select t.is_true((select deleted_at is not null from public.activity_likes
                   where id = 'aaaa1111-0000-0000-0000-000000000001'),
            'l''unlike e'' una lapide, non una DELETE');
select t.eq((select liked from public.toggle_activity_like((select anna from act),
            'aaaa1111-0000-0000-0000-000000000099')), true, 're-like -> liked');
select t.eq((select count(*) from public.activity_likes
              where activity_id = (select anna from act)
                and user_id = 'ffffffff-0000-0000-0000-000000000002'), 1::bigint,
            'e rianima la STESSA riga: l''id nuovo del retry non crea doppioni');

\echo ''
\echo '=== like: il cancello dell''autore vale anche qui'

select t.rejects(
  format($q$select public.toggle_activity_like('%s'::uuid)$q$, (select emma from act)),
  'la card di chi non ha mai consentito non si puo'' likare');

\echo ''
\echo '=== commenti: forma, thread, lettura'

select t.eq((select public.add_activity_comment((select anna from act), 'Che film!',
            'cccc1111-0000-0000-0000-000000000001')),
            'cccc1111-0000-0000-0000-000000000001'::uuid, 'il commento nasce con l''id del client');
select t.rejects(
  format($q$select public.add_activity_comment('%s'::uuid, '   ')$q$, (select anna from act)),
  'il contenuto vuoto si rifiuta alla nascita');
select t.rejects(
  format($q$select public.add_activity_comment('%s'::uuid, repeat('x', 1001))$q$, (select anna from act)),
  'e anche quello oltre i 1000');
select t.rejects(
  format($q$select public.add_activity_comment('%s'::uuid, 'reply', null,
          'cccc1111-0000-0000-0000-000000000001'::uuid)$q$, (select carla from act)),
  'una reply a un commento di un''altra attivita'' non esiste');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000001';
select t.eq((select public.add_activity_comment((select anna from act), 'Concordo!',
            'cccc1111-0000-0000-0000-000000000002',
            'cccc1111-0000-0000-0000-000000000001')),
            'cccc1111-0000-0000-0000-000000000002'::uuid, 'la reply valida entra nel thread');

select t.eq((select count(*) from public.get_activity_comments((select anna from act), 50)),
            2::bigint, 'la lettura vede il thread intero');
select t.eq((select username from public.get_activity_comments((select anna from act), 50)
              where comment_id = 'cccc1111-0000-0000-0000-000000000001'),
            'bruno2', 'con l''identita'' dell''autore');

select t.eq((select liked from public.toggle_activity_comment_like(
            'cccc1111-0000-0000-0000-000000000001')), true, 'like al commento');
select t.eq((select like_count from public.get_activity_comments((select anna from act), 50)
              where comment_id = 'cccc1111-0000-0000-0000-000000000001'), 1,
            'e il contatore lo racconta');

\echo ''
\echo '=== commenti: la cancellazione e la lapide che tiene in piedi il filo'

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000004';
select t.rejects(
  $q$select public.delete_activity_comment('cccc1111-0000-0000-0000-000000000001')$q$,
  'un terzo non cancella il commento altrui');

-- Anna e'' la proprietaria della CARD: modera casa propria anche sui commenti altrui.
set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000001';
select public.delete_activity_comment('cccc1111-0000-0000-0000-000000000001');
select t.eq((select is_deleted from public.get_activity_comments((select anna from act), 50)
              where comment_id = 'cccc1111-0000-0000-0000-000000000001'), true,
            'il commento cancellato con reply vive resta come lapide');
select t.is_true((select content is null from public.get_activity_comments((select anna from act), 50)
                   where comment_id = 'cccc1111-0000-0000-0000-000000000001'),
            'e il suo testo non c''e'' piu''');

select public.delete_activity_comment('cccc1111-0000-0000-0000-000000000002');
select t.eq((select count(*) from public.get_activity_comments((select anna from act), 50)),
            0::bigint, 'senza reply vive la lapide non serve: il thread sparisce intero');

\echo ''
\echo '=== report: idempotenti, mai sul proprio, soglia a 3'

-- Ricostruito un commento di bruno da segnalare.
set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select public.add_activity_comment((select anna from act), 'Commento discutibile',
       'cccc1111-0000-0000-0000-000000000003');

select public.report_content('activity_comment', 'cccc1111-0000-0000-0000-000000000003', 'spam');
select t.eq((select count(*) from public.content_reports
              where content_id = 'cccc1111-0000-0000-0000-000000000003'), 0::bigint,
            'segnalare il proprio contenuto e'' un no-op, non un oracolo');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000001';
select public.report_content('activity_comment', 'cccc1111-0000-0000-0000-000000000003', 'spam');
select public.report_content('activity_comment', 'cccc1111-0000-0000-0000-000000000003', 'spam');
select t.eq((select count(*) from public.content_reports
              where content_id = 'cccc1111-0000-0000-0000-000000000003'), 1::bigint,
            'lo stesso reporter conta una volta sola');

select t.eq((select count(*) from public.get_activity_comments((select anna from act), 50)
              where comment_id = 'cccc1111-0000-0000-0000-000000000003'), 1::bigint,
            'sotto soglia il commento si vede');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000003';
select public.report_content('activity_comment', 'cccc1111-0000-0000-0000-000000000003', 'spam');
set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000004';
select public.report_content('activity_comment', 'cccc1111-0000-0000-0000-000000000003', 'spam');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000001';
select t.eq((select count(*) from public.get_activity_comments((select anna from act), 50)
              where comment_id = 'cccc1111-0000-0000-0000-000000000003'), 0::bigint,
            '3 segnalatori distinti -> il commento sparisce dai lettori');
set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select t.eq((select count(*) from public.get_activity_comments((select anna from act), 50)
              where comment_id = 'cccc1111-0000-0000-0000-000000000003'), 1::bigint,
            'ma il suo autore lo vede ancora');

\echo ''
\echo '=== la review segnalata si vela, la card resta'

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000001';
insert into public.user_reviews (id, user_id, media_type, tmdb_id, content) values
  ('eeee1111-0000-0000-0000-000000000001', 'ffffffff-0000-0000-0000-000000000001',
   'movie', 42, 'Da manuale.');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select t.eq((select f.review_content from public.get_activity_feed('community', null, null, null, 50) f
              where f.activity_id = (select anna from act)), 'Da manuale.',
            'prima dei report la review viaggia');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select public.report_content('review', 'eeee1111-0000-0000-0000-000000000001', 'off topic');
set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000003';
select public.report_content('review', 'eeee1111-0000-0000-0000-000000000001', 'off topic');
set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000004';
select public.report_content('review', 'eeee1111-0000-0000-0000-000000000001', 'off topic');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select t.is_true((select f.review_content is null
                    from public.get_activity_feed('community', null, null, null, 50) f
                   where f.activity_id = (select anna from act)),
            'a 3 report il testo si vela');
select t.eq((select f.rating from public.get_activity_feed('community', null, null, null, 50) f
              where f.activity_id = (select anna from act)), 9::smallint,
            'ma il voto e la card restano: si segnala il testo, non il giudizio');
set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000001';
select t.eq((select f.review_content from public.get_activity_feed('user',
            'ffffffff-0000-0000-0000-000000000001', null, null, 50) f
              where f.activity_id = (select anna from act)), 'Da manuale.',
            'e la proprietaria vede sempre il suo testo');

\echo ''
\echo '=== i conteggi del feed sono veri'

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select t.eq((select f.like_count from public.get_activity_feed('community', null, null, null, 50) f
              where f.activity_id = (select anna from act)), 1,
            'like_count racconta i like vivi');
select t.eq((select f.liked_by_me from public.get_activity_feed('community', null, null, null, 50) f
              where f.activity_id = (select anna from act)), true,
            'liked_by_me e'' del chiamante');
select t.eq((select f.comment_count from public.get_activity_feed('community', null, null, null, 50) f
              where f.activity_id = (select anna from act)), 1,
            'comment_count conta i commenti vivi');

\echo ''
\echo '=== block_user: il blocco pota i follow nei due versi e chiude le interazioni'

-- bruno e carla si seguono, poi carla blocca bruno.
insert into public.user_follows (follower_id, followee_id) values
  ('ffffffff-0000-0000-0000-000000000002', 'ffffffff-0000-0000-0000-000000000003'),
  ('ffffffff-0000-0000-0000-000000000003', 'ffffffff-0000-0000-0000-000000000002');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000003';
select public.block_user('ffffffff-0000-0000-0000-000000000002');

select t.eq((select count(*) from public.user_follows
              where deleted_at is null
                and 'ffffffff-0000-0000-0000-000000000002' in (follower_id, followee_id)
                and 'ffffffff-0000-0000-0000-000000000003' in (follower_id, followee_id)),
            0::bigint, 'il blocco tombstona i follow in ENTRAMBI i versi');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select t.rejects(
  format($q$select public.toggle_activity_like('%s'::uuid)$q$, (select carla from act)),
  'bloccato -> la card non e'' disponibile, stessa risposta dell''inesistente');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000003';
select public.block_user('ffffffff-0000-0000-0000-000000000002');
select t.eq((select count(*) from public.user_blocks
              where user_id = 'ffffffff-0000-0000-0000-000000000003'
                and blocked_user_id = 'ffffffff-0000-0000-0000-000000000002'), 1::bigint,
            'ri-bloccare riusa la riga: due blocchi sono lo stesso blocco');

\echo ''
\echo '=== notifiche: una per (card, giorno), mai a se stessi'

-- Il like di bruno su anna (sopra) ha gia'' generato la notifica del giorno.
select t.eq((select count(*) from public.notifications
              where user_id = 'ffffffff-0000-0000-0000-000000000001'
                and notification_type = 'activity_liked'), 1::bigint,
            'il primo like fa la notifica');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000004';
select public.toggle_activity_like((select anna from act));
select t.eq((select count(*) from public.notifications
              where user_id = 'ffffffff-0000-0000-0000-000000000001'
                and notification_type = 'activity_liked'), 1::bigint,
            'il secondo like dello stesso giorno NON ne fa un''altra: dedupe per card/giorno');

select t.eq((select count(*) from public.notifications
              where user_id = 'ffffffff-0000-0000-0000-000000000001'
                and notification_type = 'activity_commented'), 1::bigint,
            'il commento di bruno ha fatto la sua (una, con la stessa dedupe)');

set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000001';
select public.toggle_activity_like((select anna from act));
select t.eq((select count(*) from public.notifications
              where user_id = 'ffffffff-0000-0000-0000-000000000001'
                and notification_type = 'activity_liked'), 1::bigint,
            'il like a se stessi non si notifica');

\echo ''
\echo '=== grant: authenticated passa, anon no'

set local role authenticated;
set local request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select t.is_true((select count(*) >= 0 from public.get_activity_comments((select anna from act), 5)),
            'authenticated legge i commenti');
reset role;

set local role anon;
select t.rejects(
  format($q$select public.toggle_activity_like('%s'::uuid)$q$, (select anna from act)),
  'anon non lika');
select t.rejects(
  $q$select public.report_content('review', 'eeee1111-0000-0000-0000-000000000001')$q$,
  'ne'' segnala');
reset role;

rollback;
