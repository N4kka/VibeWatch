-- Notification preferences v2 — the user decides the volume, and the streak nag stops being
-- the default.
--
-- **max_daily_notifications.** The dispatcher used a hardcoded DAILY_PUSH_CAP = 2 for everyone,
-- while the client carried a decorative `maxDailyNotifications` that was never sent nor read.
-- The cap becomes a column: 2 (Essential, the current behaviour and the default), 5 (Balanced),
-- 0 (Everything — no cap, every notification keeps its own banner and deep link). Anything
-- above the cap is still collapsed into a digest, exactly as before.
--
-- **streak_reminder defaults to false.** It was the single loudest producer in the system:
-- 1701 rows in 30 days across 105 users, ~92% of the whole queue, fired at every user with a
-- live streak who had not opened the app that day. It stays available as an opt-in toggle, but
-- nobody gets it unless they ask. Existing rows are reset for the same reason: they were all
-- `true` by default, never by choice — and the client has been sending a hardcoded `false` for
-- this column anyway, so most of them do not reflect an actual preference either.
--
-- **email_digest_enabled / weekly_recap_enabled.** Two cadences, two switches: the daily digest
-- is "news on what you saved", the weekly recap is closer to a newsletter. A user can plausibly
-- want one without the other and both render in the same Email section of the app.
--
-- **language / country.** Push and email copy is rendered at send time (see _shared/i18n.ts),
-- so the dispatcher needs to know which of the app's 20 locales the user reads. `country` is the
-- streaming region: availability alerts created automatically from a list have no country of
-- their own to inherit, and check-availability has been asking TMDB for Italy regardless of who
-- the subscriber was. Defaults ('en', 'IT') reproduce today's behaviour until a client syncs.

alter table public.user_notification_preferences
  add column if not exists max_daily_notifications integer not null default 2
    constraint user_notification_preferences_max_daily_check
      check (max_daily_notifications >= 0 and max_daily_notifications <= 50),
  add column if not exists email_digest_enabled boolean not null default true,
  add column if not exists weekly_recap_enabled boolean not null default true,
  add column if not exists language text not null default 'en',
  add column if not exists country text not null default 'IT';

alter table public.user_notification_preferences
  alter column streak_reminder set default false;

update public.user_notification_preferences
   set streak_reminder = false
 where streak_reminder is distinct from false;
