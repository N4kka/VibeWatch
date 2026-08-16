-- The email ledger. Two jobs, one table.
--
-- 1. **The provider budget.** Resend's free tier allows 100 messages a day and 3.000 a month,
--    and the same key also carries the auth mails (signup confirmations) that must never be the
--    ones to bounce off the ceiling. Every send counts a row here first, and the sender refuses
--    to go past a daily floor well under 100.
-- 2. **Per-user cadence.** At most one digest per user per day: the digest job is idempotent
--    against a retry or a second cron firing, without needing a lock.
--
-- 'fallback' covers the dispatcher's own path (a user with no device at all): it burns the same
-- provider budget, so it belongs in the same ledger.

create table if not exists public.email_send_log (
  id                 bigint generated always as identity primary key,
  user_id            uuid not null references auth.users(id) on delete cascade,
  email_type         text not null check (email_type in ('digest', 'weekly_recap', 'fallback')),
  item_count         integer not null default 1,
  sent_at            timestamptz not null default now()
);

create index if not exists email_send_log_sent_at_idx
  on public.email_send_log (sent_at desc);

create index if not exists email_send_log_user_type_idx
  on public.email_send_log (user_id, email_type, sent_at desc);

-- Service-role only: nothing in the app reads or writes it, and RLS with no policy is how the
-- rest of the ops tables in this schema say so.
alter table public.email_send_log enable row level security;

revoke all on table public.email_send_log from anon;
revoke all on table public.email_send_log from authenticated;
