-- Platform scaffolding for running the migrations on a plain Postgres.
--
-- Recreates only what Supabase provides and the baseline assumes: roles, the auth/storage/vault
-- schemas, the pg_net and pg_cron entry points. Every public table comes from the migrations.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;
-- Table and sequence defaults as on Supabase. Functions keep the built-in default (EXECUTE to
-- PUBLIC), which is what the baseline's `REVOKE ... FROM PUBLIC` lines are written against.
alter default privileges in schema public grant select, insert, update, delete on tables to anon, authenticated;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;

-- auth: users table and the JWT helpers. Tests drive the caller with
-- `set local request.jwt.claim.sub = '<uuid>'` (and `request.jwt.claim.role`).
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;
create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text
);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), current_user::text);
$$;

-- storage: the columns the migrations and policies touch.
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;
create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  public             boolean default false,
  file_size_limit    bigint,
  allowed_mime_types text[]
);
create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text not null,
  name       text not null,
  owner      uuid,
  owner_id   text,
  created_at timestamptz not null default now()
);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1];
$$;

-- pg_net and vault: cron jobs and triggers call them; here nothing leaves the box.
create schema if not exists net;
create or replace function net.http_post(
  url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
  headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000
) returns bigint language sql as $$ select 0::bigint $$;
create schema if not exists cron;
create table if not exists cron.job (
  jobid bigserial primary key, jobname text unique, schedule text, command text, active boolean default true
);
create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint
language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid;
$$;
create or replace function cron.unschedule(job_name text) returns boolean language sql as $$
  with d as (delete from cron.job where jobname = job_name returning 1) select exists (select 1 from d);
$$;
create schema if not exists vault;
create table if not exists vault.decrypted_secrets (name text primary key, decrypted_secret text);

-- Assertions. A failure raises: with ON_ERROR_STOP the runner exits non-zero. Executable by the
-- client roles because part of the tests impersonates the client.
create schema if not exists t;
grant usage on schema t to anon, authenticated, service_role;
alter default privileges in schema t grant execute on functions to anon, authenticated, service_role;

create or replace function t.eq(actual anyelement, expected anyelement, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL  %  (expected %, got %)', label, expected, actual;
  end if;
  raise notice 'ok    %', label;
end $$;

create or replace function t.is_true(actual boolean, label text)
returns void language plpgsql as $$
begin
  if actual is not true then
    raise exception 'FAIL  %  (expected true, got %)', label, actual;
  end if;
  raise notice 'ok    %', label;
end $$;

create or replace function t.rejects(statement text, label text)
returns void language plpgsql as $$
begin
  execute statement;
  raise exception 'FAIL  %  (statement passed, should have been rejected)', label;
exception
  when raise_exception then raise;
  when others then raise notice 'ok    %  (% )', label, sqlstate;
end $$;
