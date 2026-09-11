-- Social feed M1 — la push "ha iniziato a seguirti", e il posto delle social nel sistema push.
--
-- "X ha iniziato a seguirti" è il re-engagement più forte che un'app sociale abbia: riporta in
-- app quasi sempre, ed è raro per costruzione (con 30 MAU, più raro ancora). Per questo le
-- notifiche social hanno una CATEGORIA DI BUDGET PROPRIA in process-notifications: dentro il
-- cap generale (2/giorno) finirebbero quasi sempre nel digest dietro ai reminder episodi, cioè
-- arriverebbero fredde. La colonna `category` su notification_delivery_log è ciò che permette
-- di contare i due budget separatamente (le righe vecchie, senza categoria, contano nel
-- budget generale: è quello che erano).
--
-- I tre tipi entrano nel CHECK adesso, like e commenti compresi: il vincolo è una whitelist e
-- ampliarla è un'operazione da fare una volta — i trigger di like/commenti (M2) troveranno la
-- porta già aperta. Le preferenze seguono il meccanismo esistente di preferenceAllows: la
-- colonna si chiama COME il tipo di notifica, o il gate non la trova.

alter table public.notifications drop constraint if exists notification_type_check;
alter table public.notifications add constraint notification_type_check
  check (notification_type = any (array[
    'new_availability'::text, 'new_release'::text, 'episode_aired'::text,
    'continue_watching'::text, 'list_milestone'::text, 'price_drop'::text,
    'streak_reminder'::text, 'import_done'::text,
    'new_follower'::text, 'activity_liked'::text, 'activity_commented'::text
  ]));

alter table public.user_notification_preferences
  add column if not exists new_follower boolean not null default true,
  add column if not exists activity_liked boolean not null default true,
  add column if not exists activity_commented boolean not null default true;

alter table public.notification_delivery_log
  add column if not exists category text;

-- ------------------------------------------------------------------- trigger new_follower
--
-- Sta su `user_follows` e non in una edge function: il follow arriva via apply_mutations e il
-- trigger è l'unico punto che vede ogni strada. Il re-follow è sempre un UPDATE (la riga si
-- riusa, vedi 20260801130000): si notifica solo se l'unfollow è vecchio più di 7 giorni —
-- l'unfollow/refollow nervoso non deve diventare una raffica di push.
--
-- Il nome mostrato viene da `profiles` MA con le regole di `public_profiles`: se il follower ha
-- il profilo privato o non ha username, la push dice "Someone" — un follow non può essere il
-- canale che aggira la privacy del follower. Copy in inglese come ogni push del sistema
-- (streak-reminder, episode-radar): la localizzazione delle push è un problema non ancora
-- aperto, e non si apre da qui.
create or replace function public.tg_user_follows_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_handle text;
begin
  if new.deleted_at is not null then
    return null;
  end if;
  if tg_op = 'UPDATE' then
    if old.deleted_at is null then
      return null;  -- non è un re-follow: la riga era già viva
    end if;
    if old.deleted_at > now() - interval '7 days' then
      return null;  -- unfollow/refollow nervoso: niente raffica
    end if;
  end if;

  select coalesce('@' || p.username::text, p.display_name)
    into v_handle
    from public.profiles p
   where p.id = new.follower_id
     and p.deleted_at is null
     and p.is_profile_public
     and p.username is not null;

  insert into public.notifications
    (user_id, notification_type, title, body, category, thread_id)
  values
    (new.followee_id, 'new_follower', 'New follower',
     coalesce(v_handle, 'Someone') || ' started following you on VibeWatch.',
     'social', 'social');

  return null;
end $$;

drop trigger if exists user_follows_notify on public.user_follows;
create trigger user_follows_notify
  after insert or update on public.user_follows
  for each row execute function public.tg_user_follows_notify();

revoke all on function public.tg_user_follows_notify() from public;
revoke all on function public.tg_user_follows_notify() from anon;
revoke all on function public.tg_user_follows_notify() from authenticated;
