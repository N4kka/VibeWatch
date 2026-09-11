-- Companion to log_ai_token_usage. The client called .from('user_ai_token_usage').update({...})
-- with the local column name tokens_used_today, which does not exist on the remote schema (400),
-- and even corrected it could not create today's row because there is no INSERT RLS policy. This
-- RPC sets today's total to 0 for the caller, upserting so it works whether or not a row exists.
-- Same ownership rule as the logger: a signed-in user may only reset their own usage.
CREATE OR REPLACE FUNCTION public.reset_ai_token_usage(
  p_user_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'reset_ai_token_usage: cannot reset token usage for another user';
  END IF;

  INSERT INTO public.user_ai_token_usage (user_id, usage_date, total_tokens_used, last_updated)
  VALUES (p_user_id, CURRENT_DATE, 0, now())
  ON CONFLICT (user_id, usage_date)
  DO UPDATE SET total_tokens_used = 0, last_updated = now();

  RETURN 0;
END;
$$;

-- Revoke anon for the same reason as log_ai_token_usage: the NULL-uid path is meant for the
-- service role, and anon must not be able to reset another user's counter.
REVOKE ALL ON FUNCTION public.reset_ai_token_usage(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reset_ai_token_usage(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.reset_ai_token_usage(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_ai_token_usage(uuid) TO service_role;
