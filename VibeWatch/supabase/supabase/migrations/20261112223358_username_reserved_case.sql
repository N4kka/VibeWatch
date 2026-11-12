-- Usernames are citext, but functions run with search_path = public, where citext's operators are
-- not visible: `r.name = new.username` fell back to a case-sensitive text comparison, so a direct
-- PATCH to 'VibeWatch' or 'Admin' slipped past the reserved list. The format check had the
-- opposite problem: its explicit citext regex ignored case, so mixed-case names passed it.

alter table public.profiles drop constraint profiles_username_format;
alter table public.profiles add constraint profiles_username_format
  check (username is null or username::text ~ '^[a-z0-9_]{3,20}$');

create or replace function public.tg_profiles_username_changed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.username is distinct from old.username then
    if new.username is not null
       and exists (select 1 from public.username_reserved r
                    where lower(r.name::text) = lower(new.username::text)) then
      raise exception 'username_reserved' using errcode = '23514';
    end if;
    new.username_changed_at := now();
  else
    new.username_changed_at := old.username_changed_at;
  end if;
  return new;
end $$;
