-- An FCM token identifies a handset, and it belongs to the account that signed in last on it.
--
-- `fcm_token` is UNIQUE across the table, but the upsert only handled a conflict on
-- (user_id, fcm_token): when a second account signed in on the same device the insert failed,
-- so that account never got pushes while the device kept receiving the previous account's.
create or replace function public.register_user_device(p_fcm_token text, p_platform text default 'ios')
returns void
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
begin
  if auth.uid() is null then
    raise exception 'User must be authenticated to register device tokens';
  end if;

  -- Null rather than delete: an account with no row at all is switched to the email fallback.
  update user_devices
     set fcm_token = null
   where fcm_token = p_fcm_token
     and user_id <> auth.uid();

  insert into user_devices (user_id, fcm_token, platform)
  values (auth.uid(), p_fcm_token, coalesce(nullif(p_platform, ''), 'ios'))
  on conflict (user_id, fcm_token)
  do update set
    platform = excluded.platform,
    updated_at = now();
end;
$$;
