-- DEFERRED — do not apply with the rest of the notifications refactor.
--
-- `list_milestone` and `price_drop` are dead: no producer has ever written a notification of
-- either type, and both left the CHECK constraint, the dispatcher and the app in the
-- 20260815101000 migration. What keeps the two columns alive is the installed base: the app
-- upserts its preferences straight through PostgREST with an explicit column list, and PostgREST
-- rejects the *entire* payload when one column does not exist. Dropping these while an older
-- build is still around would not silently ignore two dead toggles — it would break every
-- preference change those users make (quiet hours, social toggles, push on/off included), and
-- the client only logs that failure.
--
-- Apply this once the release that stopped sending the two columns is the dominant client.
-- Check before running:
--
--   select count(*) filter (where max_daily_notifications <> 2) as new_clients, count(*)
--     from public.user_notification_preferences;

alter table public.user_notification_preferences
  drop column if exists price_drop,
  drop column if exists list_milestone;
