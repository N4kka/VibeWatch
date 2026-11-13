-- `register_user_device`: an FCM token belongs to the account that signed in last on that device.
--
-- Run with supabase/tests/run.sh. A failed assertion stops everything.

\set ON_ERROR_STOP on
\set QUIET 1
\pset pager off
\pset tuples_only on
\pset footer off

begin;

insert into auth.users (id, email) values
  ('dddddddd-0000-0000-0000-000000000001', 'anna@test'),
  ('dddddddd-0000-0000-0000-000000000002', 'bruno@test');

\echo ''
\echo '=== same handset, second account'

set local role authenticated;
set local request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000001';
select public.register_user_device('token-shared', 'ios');
select public.register_user_device('token-shared', 'ios');
reset role;

select t.eq((select count(*) from public.user_devices where fcm_token = 'token-shared'), 1::bigint,
            're-registering the same token keeps one row');

set local role authenticated;
set local request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000002';
select public.register_user_device('token-shared', 'ios');
reset role;

select t.eq((select user_id from public.user_devices where fcm_token = 'token-shared'),
            'dddddddd-0000-0000-0000-000000000002'::uuid,
            'the token now delivers to the account signed in last');
select t.eq((select count(*) from public.user_devices
              where user_id = 'dddddddd-0000-0000-0000-000000000001' and fcm_token is null), 1::bigint,
            'the previous account keeps its row with a null token (silence, not the email fallback)');

\echo ''
\echo '=== back to the first account'

set local role authenticated;
set local request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000001';
select public.register_user_device('token-shared', 'ios');
reset role;

select t.eq((select user_id from public.user_devices where fcm_token = 'token-shared'),
            'dddddddd-0000-0000-0000-000000000001'::uuid,
            'the token moves back to the first account');

set local role anon;
select t.rejects('select public.register_user_device(''token-anon'', ''ios'')',
                 'anon cannot register a device');
reset role;

rollback;
