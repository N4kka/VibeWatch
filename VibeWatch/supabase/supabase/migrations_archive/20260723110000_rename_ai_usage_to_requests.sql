-- Resolve the requests-vs-tokens ambiguity. Everything in this path actually counts daily
-- REQUESTS (free 5 / pro 10): cerebras-proxy increments by 1 per request, the client's
-- recordUsage() increments by 1, and the limit check is a request count. Only the naming said
-- "tokens" — the column total_tokens_used, the RPC parameter, and the client symbols. The column
-- is the real data element, so it is renamed to request_count and the three functions are updated
-- to match.
--
-- The function NAMES are deliberately kept (get_/log_/reset_ai_token_usage): the shipped 2.4 app
-- calls them by name over PostgREST, so renaming them would break production. Only the column and
-- the log parameter (which no shipped client calls — the client path is dead code; the only caller
-- is cerebras-proxy, redeployed alongside this) change.

ALTER TABLE public.user_ai_token_usage RENAME COLUMN total_tokens_used TO request_count;

-- Reader: unchanged behaviour, reads the renamed column.
CREATE OR REPLACE FUNCTION public.get_ai_token_usage(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
DECLARE
  used integer;
BEGIN
  SELECT request_count INTO used
  FROM public.user_ai_token_usage
  WHERE user_id = p_user_id AND usage_date = CURRENT_DATE;

  RETURN COALESCE(used, 0);
END;
$$;

-- Writer: renamed parameter (p_requests) and column. Records one or more AI requests for today,
-- returning the running count. DROP + CREATE because a parameter name cannot be changed via
-- CREATE OR REPLACE.
DROP FUNCTION IF EXISTS public.log_ai_token_usage(uuid, integer);
CREATE FUNCTION public.log_ai_token_usage(
  p_user_id uuid,
  p_requests integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  new_total integer;
BEGIN
  IF p_requests IS NULL OR p_requests < 0 THEN
    RAISE EXCEPTION 'log_ai_token_usage: p_requests must be a non-negative integer';
  END IF;

  -- A signed-in user may only record their own requests. auth.uid() is null for the service role
  -- (cerebras-proxy), which is allowed to record on a user's behalf. anon is revoked below, so a
  -- null auth.uid() here can only be the service role.
  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'log_ai_token_usage: cannot log requests for another user';
  END IF;

  INSERT INTO public.user_ai_token_usage (user_id, usage_date, request_count, last_updated)
  VALUES (p_user_id, CURRENT_DATE, p_requests, now())
  ON CONFLICT (user_id, usage_date)
  DO UPDATE SET
    request_count = public.user_ai_token_usage.request_count + EXCLUDED.request_count,
    last_updated = now()
  RETURNING request_count INTO new_total;

  RETURN new_total;
END;
$$;

REVOKE ALL ON FUNCTION public.log_ai_token_usage(uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_ai_token_usage(uuid, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_ai_token_usage(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_ai_token_usage(uuid, integer) TO service_role;

-- Reset: writes the renamed column.
CREATE OR REPLACE FUNCTION public.reset_ai_token_usage(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'reset_ai_token_usage: cannot reset requests for another user';
  END IF;

  INSERT INTO public.user_ai_token_usage (user_id, usage_date, request_count, last_updated)
  VALUES (p_user_id, CURRENT_DATE, 0, now())
  ON CONFLICT (user_id, usage_date)
  DO UPDATE SET request_count = 0, last_updated = now();

  RETURN 0;
END;
$$;
