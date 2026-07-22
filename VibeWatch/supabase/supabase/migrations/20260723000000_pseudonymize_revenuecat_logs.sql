-- Account deletion: pseudonymize RevenueCat webhook logs instead of orphaning them.
--
-- revenuecat_webhook_logs has no foreign key to auth.users, so unlike the ~28 tables that
-- cascade from auth.users it survives auth.admin.deleteUser() untouched. The rows are billing
-- records worth retaining for accounting purposes (GDPR Art. 17(3) permits retention for legal
-- obligations), so they are pseudonymized rather than deleted: the transaction history stays
-- intact while the link to the person is severed.
--
-- The identifier appears in several places, not just the app_user_id column:
--   payload.app_user_id, payload.original_app_user_id, payload.aliases[]
-- and payload.subscriber_attributes can carry $email / $phoneNumber / $displayName. All of
-- them have to be rewritten, otherwise the column is scrubbed while the payload still identifies
-- the user.
--
-- The pseudonym is supplied by the caller (a SHA-256 digest of the user id) so it is
-- deterministic: rows belonging to the same deleted user still group together for accounting,
-- but the original id cannot be recovered from the stored value.

CREATE OR REPLACE FUNCTION public.pseudonymize_revenuecat_logs(
  p_user_id text,
  p_pseudonym text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  affected integer;
BEGIN
  IF p_user_id IS NULL OR p_user_id = '' OR p_pseudonym IS NULL OR p_pseudonym = '' THEN
    RAISE EXCEPTION 'pseudonymize_revenuecat_logs: user id and pseudonym are both required';
  END IF;

  UPDATE revenuecat_webhook_logs
  SET
    app_user_id = p_pseudonym,
    payload = payload
      || jsonb_build_object(
           'app_user_id', to_jsonb(p_pseudonym),
           'original_app_user_id', to_jsonb(p_pseudonym),
           -- The alias list can also hold the RevenueCat anonymous id, which identifies the
           -- same person, so the whole array is replaced rather than filtered.
           'aliases', jsonb_build_array(to_jsonb(p_pseudonym))
         )
      || CASE
           WHEN jsonb_typeof(payload -> 'subscriber_attributes') = 'object'
           THEN jsonb_build_object(
                  'subscriber_attributes',
                  (payload -> 'subscriber_attributes') - '$email' - '$phoneNumber' - '$displayName'
                )
           ELSE '{}'::jsonb
         END
  WHERE app_user_id = p_user_id
     OR payload ->> 'app_user_id' = p_user_id
     OR payload ->> 'original_app_user_id' = p_user_id
     OR (jsonb_typeof(payload -> 'aliases') = 'array' AND payload -> 'aliases' ? p_user_id);

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

-- Only the service/secret key may invoke this; it must never be reachable from the app clients.
REVOKE ALL ON FUNCTION public.pseudonymize_revenuecat_logs(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pseudonymize_revenuecat_logs(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.pseudonymize_revenuecat_logs(text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.pseudonymize_revenuecat_logs(text, text) TO service_role;
