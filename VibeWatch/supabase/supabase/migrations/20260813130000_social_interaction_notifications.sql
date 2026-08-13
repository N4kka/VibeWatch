-- Social feed M2 — le push di like e commenti (i tipi e le preferenze esistono dalla M1:
-- 20260812190000 ha già allargato il CHECK e aggiunto activity_liked/activity_commented alle
-- preferenze — la porta era aperta apposta).
--
-- **Dedupe per (attività, giorno), portata da thread_id.** `notifications` non ha una colonna
-- per l'attore né per l'attività; `thread_id` è text e finisce nell'APNs thread — usarlo come
-- `social:{activity_id}` compra due cose con una colonna: il raggruppamento delle banner per
-- card sul device, e la chiave di dedupe qui (una notifica di like per card al giorno, idem
-- commenti). Dieci like sulla stessa card in un'ora sono UNA notifica, non dieci: il cap
-- social (3/dì) deve pagare gesti diversi, non lo stesso gesto ripetuto.
--
-- Il nome mostrato segue le regole di public_profiles (profilo privato -> "Someone"), come la
-- push del follow. Copy in inglese come tutto il sistema push.

create or replace function public.tg_activity_likes_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner  uuid;
  v_title  text;
  v_handle text;
begin
  if new.deleted_at is not null then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is null then
    return null;  -- nessuna transizione verso "liked": niente da dire
  end if;

  select a.user_id, a.title into v_owner, v_title
    from public.activities a
   where a.id = new.activity_id and a.deleted_at is null;
  if v_owner is null or v_owner = new.user_id then
    return null;
  end if;

  if exists (
       select 1 from public.notifications n
        where n.user_id = v_owner
          and n.notification_type = 'activity_liked'
          and n.thread_id = 'social:' || new.activity_id
          and n.created_at >= date_trunc('day', now())
     ) then
    return null;
  end if;

  select coalesce('@' || p.username::text, p.display_name)
    into v_handle
    from public.profiles p
   where p.id = new.user_id
     and p.deleted_at is null
     and p.is_profile_public
     and p.username is not null;

  insert into public.notifications
    (user_id, notification_type, title, body, category, thread_id)
  values
    (v_owner, 'activity_liked', 'New like',
     coalesce(v_handle, 'Someone') || ' liked your activity'
       || coalesce(' about ' || v_title, '') || '.',
     'social', 'social:' || new.activity_id);

  return null;
end $$;

drop trigger if exists activity_likes_notify on public.activity_likes;
create trigger activity_likes_notify
  after insert or update on public.activity_likes
  for each row execute function public.tg_activity_likes_notify();

create or replace function public.tg_activity_comments_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner  uuid;
  v_title  text;
  v_handle text;
begin
  if new.deleted_at is not null then
    return null;
  end if;

  select a.user_id, a.title into v_owner, v_title
    from public.activities a
   where a.id = new.activity_id and a.deleted_at is null;
  if v_owner is null or v_owner = new.user_id then
    return null;
  end if;

  if exists (
       select 1 from public.notifications n
        where n.user_id = v_owner
          and n.notification_type = 'activity_commented'
          and n.thread_id = 'social:' || new.activity_id
          and n.created_at >= date_trunc('day', now())
     ) then
    return null;
  end if;

  select coalesce('@' || p.username::text, p.display_name)
    into v_handle
    from public.profiles p
   where p.id = new.user_id
     and p.deleted_at is null
     and p.is_profile_public
     and p.username is not null;

  insert into public.notifications
    (user_id, notification_type, title, body, category, thread_id)
  values
    (v_owner, 'activity_commented', 'New comment',
     coalesce(v_handle, 'Someone') || ' commented on your activity'
       || coalesce(' about ' || v_title, '') || '.',
     'social', 'social:' || new.activity_id);

  return null;
end $$;

drop trigger if exists activity_comments_notify on public.activity_comments;
create trigger activity_comments_notify
  after insert on public.activity_comments
  for each row execute function public.tg_activity_comments_notify();

revoke all on function public.tg_activity_likes_notify() from public;
revoke all on function public.tg_activity_likes_notify() from anon;
revoke all on function public.tg_activity_likes_notify() from authenticated;
revoke all on function public.tg_activity_comments_notify() from public;
revoke all on function public.tg_activity_comments_notify() from anon;
revoke all on function public.tg_activity_comments_notify() from authenticated;
