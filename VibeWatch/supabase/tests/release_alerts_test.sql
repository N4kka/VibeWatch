-- Auto-iscrizione agli avvisi: salvare un titolo È l'iscrizione.
--
-- Il comportamento vecchio (solo la watchlist, e solo all'insert) copriva 8 iscrizioni su tutta
-- la base utenti. Qui si verifica quello nuovo, con particolare attenzione ai due modi in cui si
-- puo' sbagliare: ritirare un avviso che l'utente aveva chiesto a mano, e ritirarne uno per un
-- titolo che sta ancora in un'altra lista.
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
  ('bbbbbbbb-0000-0000-0000-000000000001', 'alerts-a@test'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'alerts-b@test');

insert into public.user_notification_preferences (user_id, country) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'DE');

insert into public.lists (id, user_id, name, type) values
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Watchlist', 'watchlist'),
  ('cccccccc-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001', 'Sabato sera', 'custom'),
  ('cccccccc-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000002', 'Watchlist', 'watchlist');

\echo ''
\echo '=== salvare un titolo crea l''iscrizione, in qualunque lista'

insert into public.list_items (id, list_id, user_id, media_id, media_type) values
  ('dddddddd-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001', 101, 'movie');

select t.eq(
  (select source from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 101),
  'watchlist', 'un item in watchlist si iscrive come watchlist');

insert into public.list_items (id, list_id, user_id, media_id, media_type) values
  ('dddddddd-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000002',
   'bbbbbbbb-0000-0000-0000-000000000001', 202, 'tv');

select t.eq(
  (select source from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 202),
  'custom_list', 'una lista personalizzata si iscrive lo stesso: e'' il punto del refactoring');

select t.eq(
  (select country_code from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 202),
  'DE', 'il paese arriva dalle preferenze dell''utente, non da una costante');

select t.eq(
  (select count(*)::int from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  2, 'due titoli salvati, due iscrizioni');

\echo ''
\echo '=== un utente senza preferenze ricade su IT, come faceva il codice prima'

insert into public.list_items (id, list_id, user_id, media_id, media_type) values
  ('dddddddd-0000-0000-0000-000000000003', 'cccccccc-0000-0000-0000-000000000003',
   'bbbbbbbb-0000-0000-0000-000000000002', 303, 'movie');

select t.eq(
  (select country_code from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000002' and media_id = 303),
  'IT', 'nessuna riga di preferenze: IT');

\echo ''
\echo '=== lo stesso titolo in due liste si ritira solo quando esce da entrambe'

insert into public.list_items (id, list_id, user_id, media_id, media_type) values
  ('dddddddd-0000-0000-0000-000000000004', 'cccccccc-0000-0000-0000-000000000002',
   'bbbbbbbb-0000-0000-0000-000000000001', 101, 'movie');

-- Rimozione soft, come la scrive apply_mutations quando il client sincronizza una rimozione.
update public.list_items set deleted_at = now()
 where id = 'dddddddd-0000-0000-0000-000000000001';

select t.is_true(
  (select is_active from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 101),
  'tolto dalla watchlist ma ancora nella lista personalizzata: l''avviso resta');

-- Rimozione hard, l'altra strada di apply_mutations (op = 'DELETE').
delete from public.list_items where id = 'dddddddd-0000-0000-0000-000000000004';

select t.eq(
  (select is_active from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 101),
  false, 'uscito da ogni lista: l''avviso si ritira');

select t.is_true(
  (select deleted_at is not null from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 101),
  'ritirato con deleted_at, non cancellato: last_notified_at deve sopravvivere');

\echo ''
\echo '=== ri-salvare un titolo ritirato lo riattiva'

insert into public.list_items (id, list_id, user_id, media_id, media_type) values
  ('dddddddd-0000-0000-0000-000000000005', 'cccccccc-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001', 101, 'movie');

select t.is_true(
  (select is_active and deleted_at is null from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 101),
  'riattivato, sulla stessa riga');

\echo ''
\echo '=== un "Avvisami" esplicito non viene mai declassato ne'' ritirato'

insert into public.release_alerts (user_id, media_id, media_type, source, is_active, country_code)
values ('bbbbbbbb-0000-0000-0000-000000000001', 404, 'movie', 'notify_me', true, 'DE');

insert into public.list_items (id, list_id, user_id, media_id, media_type) values
  ('dddddddd-0000-0000-0000-000000000006', 'cccccccc-0000-0000-0000-000000000002',
   'bbbbbbbb-0000-0000-0000-000000000001', 404, 'movie');

select t.eq(
  (select source from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 404),
  'notify_me', 'salvarlo in lista non declassa la scelta esplicita ad automatica');

delete from public.list_items where id = 'dddddddd-0000-0000-0000-000000000006';

select t.is_true(
  (select is_active from public.release_alerts
    where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and media_id = 404),
  'toglierlo dalla lista non spegne cio'' che l''utente aveva chiesto a mano');

\echo ''
\echo '=== il trigger vecchio non c''e'' piu'''

select t.eq(
  (select count(*)::int from pg_trigger tg
     join pg_class c on c.oid = tg.tgrelid
    where c.relname = 'list_items' and tg.tgname = 'list_items_create_alert'),
  0, 'trg_create_alert_on_watchlist rimosso: due trigger che scrivono la stessa riga litigano');

rollback;
