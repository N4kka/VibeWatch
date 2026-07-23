-- The client calls an RPC `log_ai_token_usage(p_user_id, p_tokens_consumed)` after every AI
-- interaction, but the function was never created: the call 404s and the app silently falls back
-- to a local-only counter. The consequence is that the daily AI-token quota is not enforced on the
-- server at all — user_ai_token_usage holds zero rows — so a user resets their usage by reinstalling
-- or spreads it across devices. This creates the missing writer to match the existing reader,
-- get_ai_token_usage.
--
-- Two things blocked a plain client-side upsert, which is why this is an RPC and not a table write:
--   1. user_ai_token_usage has SELECT and UPDATE RLS policies but no INSERT policy, so the first
--      write of each day was rejected.
--   2. The client sent the local SQLite column names (tokens_used_today), not the remote schema
--      (total_tokens_used, usage_date).
-- SECURITY DEFINER lets the function insert past the missing policy, but it must not become a way to
-- inflate someone else's quota: an authenticated caller may only log for their own id. Service-role
-- callers (auth.uid() is null) may log for any user.

CREATE OR REPLACE FUNCTION public.log_ai_token_usage(
  p_user_id uuid,
  p_tokens_consumed integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  new_total integer;
BEGIN
  IF p_tokens_consumed IS NULL OR p_tokens_consumed < 0 THEN
    RAISE EXCEPTION 'log_ai_token_usage: p_tokens_consumed must be a non-negative integer';
  END IF;

  -- A signed-in user can only ever record their own consumption. auth.uid() is null for the
  -- service role, which is allowed to log on behalf of any user.
  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'log_ai_token_usage: cannot log token usage for another user';
  END IF;

  INSERT INTO public.user_ai_token_usage (user_id, usage_date, total_tokens_used, last_updated)
  VALUES (p_user_id, CURRENT_DATE, p_tokens_consumed, now())
  ON CONFLICT (user_id, usage_date)
  DO UPDATE SET
    total_tokens_used = public.user_ai_token_usage.total_tokens_used + EXCLUDED.total_tokens_used,
    last_updated = now()
  RETURNING total_tokens_used INTO new_total;

  RETURN new_total;
END;
$$;

-- anon and service_role both have auth.uid() = NULL, and the ownership guard above lets NULL
-- through so that server-side callers (cerebras-proxy runs as service_role) can log on a user's
-- behalf. That means anon MUST NOT be able to reach the function, or an unauthenticated caller
-- could inflate any user's quota. Supabase grants EXECUTE to anon via default privileges, which
-- REVOKE FROM PUBLIC does not remove, so anon is revoked explicitly.
REVOKE ALL ON FUNCTION public.log_ai_token_usage(uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_ai_token_usage(uuid, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_ai_token_usage(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_ai_token_usage(uuid, integer) TO service_role;

-- Third reason the write path was broken: a BEFORE UPDATE trigger ran the shared set_updated_at()
-- function, which assigns NEW.updated_at, but this table has last_updated. Every UPDATE raised.
-- The function is shared with tables that do have updated_at, so only this table's trigger is
-- dropped; both RPCs above set last_updated explicitly.
DROP TRIGGER IF EXISTS user_ai_token_usage_set_updated_at ON public.user_ai_token_usage;
