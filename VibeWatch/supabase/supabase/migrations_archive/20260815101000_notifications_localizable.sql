-- Localizable notification copy, and the removal of the two types nobody ever produced.
--
-- **Why the queue stops carrying finished sentences.** Every producer wrote `title`/`body` in
-- English at enqueue time, so the language of a push was decided by whoever inserted the row —
-- hours before delivery, without knowing who would read it. The row now carries what the
-- notification *is* (`template_key`) and the parts that vary (`template_params`), and the
-- dispatcher renders it in the recipient's language at send time (_shared/i18n.ts).
--
-- `title`/`body` stay NOT NULL and keep being written in English by every producer: they are the
-- fallback for a key the renderer does not know (an older function still deployed, a row queued
-- before this migration) and they keep the table readable in the SQL editor. Nothing breaks if
-- the two columns are the only thing a row has.
--
-- **list_milestone and price_drop leave the whitelist.** Both have been in the CHECK constraint,
-- in the preferences and (for the milestone) in the app's settings screen since the beginning,
-- and neither has ever had a producer: not one row in the table's history. Removing them from
-- the constraint is the part that is safe to do now; the preference columns stay until the app
-- release that stops sending them (see the deferred drop migration) because old clients upsert
-- the full column list and PostgREST rejects the whole payload on an unknown column.

alter table public.notifications
  add column if not exists template_key text,
  add column if not exists template_params jsonb;

delete from public.notifications
 where notification_type in ('list_milestone', 'price_drop');

alter table public.notifications drop constraint if exists notification_type_check;
alter table public.notifications add constraint notification_type_check
  check (notification_type = any (array[
    'new_availability'::text, 'new_release'::text, 'episode_aired'::text,
    'continue_watching'::text, 'streak_reminder'::text, 'import_done'::text,
    'new_follower'::text, 'activity_liked'::text, 'activity_commented'::text
  ]));

-- ------------------------------------------------------------------ social triggers, localized
--
-- The three social producers are DB triggers, so they are the only producers that cannot be
-- fixed by redeploying an edge function. Same logic as before (dedupe per activity/day through
-- thread_id, "Someone" when the actor's profile is not public) — they now also state the key and
-- the parameters, and keep writing the English sentence as the fallback.

create or replace function public.tg_user_follows_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_handle text;
  v_name   text;
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

  -- 'Someone' is the fallback *value*, not a fallback sentence: the renderer localizes it too.
  v_name := coalesce(v_handle, '');

  insert into public.notifications
    (user_id, notification_type, title, body, category, thread_id,
     template_key, template_params)
  values
    (new.followee_id, 'new_follower', 'New follower',
     coalesce(v_handle, 'Someone') || ' started following you on VibeWatch.',
     'social', 'social',
     'new_follower', jsonb_build_object('name', v_name));

  return null;
end $$;

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
    (user_id, notification_type, title, body, category, thread_id,
     template_key, template_params)
  values
    (v_owner, 'activity_liked', 'New like',
     coalesce(v_handle, 'Someone') || ' liked your activity'
       || coalesce(' about ' || v_title, '') || '.',
     'social', 'social:' || new.activity_id,
     case when v_title is null then 'activity_liked' else 'activity_liked_about' end,
     jsonb_build_object('name', coalesce(v_handle, ''), 'title', coalesce(v_title, '')));

  return null;
end $$;

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
    (user_id, notification_type, title, body, category, thread_id,
     template_key, template_params)
  values
    (v_owner, 'activity_commented', 'New comment',
     coalesce(v_handle, 'Someone') || ' commented on your activity'
       || coalesce(' about ' || v_title, '') || '.',
     'social', 'social:' || new.activity_id,
     case when v_title is null then 'activity_commented' else 'activity_commented_about' end,
     jsonb_build_object('name', coalesce(v_handle, ''), 'title', coalesce(v_title, '')));

  return null;
end $$;

revoke all on function public.tg_user_follows_notify() from public;
revoke all on function public.tg_user_follows_notify() from anon;
revoke all on function public.tg_user_follows_notify() from authenticated;
revoke all on function public.tg_activity_likes_notify() from public;
revoke all on function public.tg_activity_likes_notify() from anon;
revoke all on function public.tg_activity_likes_notify() from authenticated;
revoke all on function public.tg_activity_comments_notify() from public;
revoke all on function public.tg_activity_comments_notify() from anon;
revoke all on function public.tg_activity_comments_notify() from authenticated;
