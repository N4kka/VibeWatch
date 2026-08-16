-- Per-user push budget bookkeeping.
--
-- Counting deliveries off `notifications.sent_at` does not work: that column is also stamped on
-- rows retired for preferences, on rows collapsed into a digest, and on rows dropped as stale.
-- One row here == one push actually handed to FCM, which is the only thing a rate limit can
-- honestly be measured against.
create table if not exists public.notification_delivery_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  delivered_at timestamptz not null default now(),
  kind text not null check (kind in ('single', 'digest')),
  notification_count integer not null default 1
);

create index if not exists notification_delivery_log_user_time
  on public.notification_delivery_log (user_id, delivered_at desc);

-- Written and read exclusively by process-notifications with the secret key, which bypasses RLS.
-- RLS on with no policy means no client role can reach it.
alter table public.notification_delivery_log enable row level security;
