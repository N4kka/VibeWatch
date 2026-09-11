-- The notification pipeline's schedules, finally in the repo.
--
-- Every cron in this file already existed in production, created by hand from the dashboard: the
-- schedules were readable only by querying `cron.job` on the live database, and a restore from
-- migrations alone would have brought up a system that queues notifications and never sends them.
-- Re-running this file is safe — each job is unscheduled by name first — and it is also the file
-- that adds the two email jobs.
--
-- **Order matters between the last two.** `weekly-recap` runs an hour after the Sunday
-- `email-digest`, so on the one day both fire the digest claims the provider budget first: news
-- about a title you saved outranks a newsletter.
--
-- All jobs authenticate as the service caller through the vaulted `edge_service_key`
-- (_shared/cronAuth.ts). The three functions that read the Authorization header rather than the
-- apikey header get both, exactly as they do in production today.

do $$
declare
  v_job text;
begin
  foreach v_job in array array[
    'process-notifications', 'episode-radar', 'release-radar',
    'check-all-availability', 'continue-watching-reminder', 'streak-reminder',
    'prune-user-devices', 'email-digest', 'weekly-recap'
  ] loop
    if exists (select 1 from cron.job where jobname = v_job) then
      perform cron.unschedule(v_job);
    end if;
  end loop;
end $$;

-- Drains the queue: preferences, quiet hours, per-user daily cap, FCM, email fallback.
select cron.schedule(
  'process-notifications',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/process-notifications',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);

-- 05:30, right after refresh-backlog (05:00) has recomputed tv_show_state.
select cron.schedule(
  'episode-radar',
  '30 5 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/episode-radar',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);

select cron.schedule(
  'check-all-availability',
  '0 6 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/check-all-availability',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);

select cron.schedule(
  'release-radar',
  '0 7 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/release-radar',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);

select cron.schedule(
  'continue-watching-reminder',
  '0 18 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/continue-watching-reminder',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);

-- Opt-in only since the preferences v2 migration: this queues nothing for anyone who has not
-- asked for it.
select cron.schedule(
  'streak-reminder',
  '0 20 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/streak-reminder',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);

-- Keeps the newest five tokens per user. Without it one account reached 66 device rows and every
-- notification was delivered 66 times.
select cron.schedule(
  'prune-user-devices',
  '15 3 * * 0',
  $$select public.prune_user_devices(5);$$
);

-- 17:00 UTC: late enough to have collected the day's releases (07:00) and availability (06:00),
-- early enough to land in the evening across Europe.
select cron.schedule(
  'email-digest',
  '0 17 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/email-digest',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);

select cron.schedule(
  'weekly-recap',
  '0 18 * * 0',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/weekly-recap',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);
