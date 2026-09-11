-- user_devices grows one row per FCM token rotation and nothing ever removed the old ones:
-- 324 rows for 234 users, one account alone holding 66. Every one of them was a separate FCM
-- call per notification, and several stale tokens on the same handset mean the same push
-- arriving more than once.
--
-- Deliberately keeps the N most recent rows per user and nothing else. No deletion by age and
-- no deletion of dead tokens: a user left with zero rows would be treated as "never registered
-- for push" and start receiving the email fallback instead, which is exactly the wrong outcome
-- for someone who uninstalled the app.
create or replace function public.prune_user_devices(p_keep integer default 5)
returns integer
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_deleted integer;
begin
  with ranked as (
    select id, row_number() over (partition by user_id order by updated_at desc) as rn
    from public.user_devices
  )
  delete from public.user_devices d
  using ranked
  where d.id = ranked.id
    and ranked.rn > greatest(p_keep, 1);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$function$;

-- Housekeeping only; no client role has any business calling it.
revoke all on function public.prune_user_devices(integer) from public, anon, authenticated;
