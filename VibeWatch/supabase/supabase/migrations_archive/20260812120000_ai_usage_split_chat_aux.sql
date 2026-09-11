-- Split the AI daily quota into two buckets. request_count stays the CHAT counter (the badge in
-- the app and get_ai_token_usage keep reading it unchanged); aux_request_count is the new counter
-- for the non-chat AI features (why-for-me, loglines, embeddings, session vibe, nudges, search
-- expansion) that until now burned the user's chat quota. cerebras-proxy decides the bucket from
-- a client-sent feature tag and calls log_ai_request_usage with it.
--
-- Also adds a global daily token ledger (ai_global_usage) used by cerebras-proxy as a circuit
-- breaker for the Cerebras key's 1M tokens/day budget.

ALTER TABLE public.user_ai_token_usage
  ADD COLUMN IF NOT EXISTS aux_request_count integer NOT NULL DEFAULT 0;

-- Bucket-aware writer. Same security model as log_ai_token_usage: signed-in users may only log
-- their own requests; a null auth.uid() can only be the service role because anon is revoked.
CREATE FUNCTION public.log_ai_request_usage(
  p_user_id uuid,
  p_bucket text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  new_total integer;
BEGIN
  IF p_bucket IS NULL OR p_bucket NOT IN ('chat', 'aux') THEN
    RAISE EXCEPTION 'log_ai_request_usage: p_bucket must be ''chat'' or ''aux''';
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'log_ai_request_usage: cannot log requests for another user';
  END IF;

  IF p_bucket = 'chat' THEN
    INSERT INTO public.user_ai_token_usage (user_id, usage_date, request_count, last_updated)
    VALUES (p_user_id, CURRENT_DATE, 1, now())
    ON CONFLICT (user_id, usage_date)
    DO UPDATE SET
      request_count = public.user_ai_token_usage.request_count + 1,
      last_updated = now()
    RETURNING request_count INTO new_total;
  ELSE
    INSERT INTO public.user_ai_token_usage (user_id, usage_date, aux_request_count, last_updated)
    VALUES (p_user_id, CURRENT_DATE, 1, now())
    ON CONFLICT (user_id, usage_date)
    DO UPDATE SET
      aux_request_count = public.user_ai_token_usage.aux_request_count + 1,
      last_updated = now()
    RETURNING aux_request_count INTO new_total;
  END IF;

  RETURN new_total;
END;
$$;

REVOKE ALL ON FUNCTION public.log_ai_request_usage(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_ai_request_usage(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_ai_request_usage(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_ai_request_usage(uuid, text) TO service_role;

-- Global daily token ledger for the circuit breaker. Only cerebras-proxy (service role) touches
-- it; no client access at all.
CREATE TABLE IF NOT EXISTS public.ai_global_usage (
  usage_date date PRIMARY KEY,
  total_tokens bigint NOT NULL DEFAULT 0,
  last_updated timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.ai_global_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_global_usage FROM PUBLIC;
REVOKE ALL ON TABLE public.ai_global_usage FROM anon;
REVOKE ALL ON TABLE public.ai_global_usage FROM authenticated;

CREATE FUNCTION public.log_ai_global_tokens(p_tokens integer)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  new_total bigint;
BEGIN
  IF p_tokens IS NULL OR p_tokens < 0 THEN
    RAISE EXCEPTION 'log_ai_global_tokens: p_tokens must be a non-negative integer';
  END IF;

  INSERT INTO public.ai_global_usage (usage_date, total_tokens, last_updated)
  VALUES (CURRENT_DATE, p_tokens, now())
  ON CONFLICT (usage_date)
  DO UPDATE SET
    total_tokens = public.ai_global_usage.total_tokens + EXCLUDED.total_tokens,
    last_updated = now()
  RETURNING total_tokens INTO new_total;

  RETURN new_total;
END;
$$;

REVOKE ALL ON FUNCTION public.log_ai_global_tokens(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_ai_global_tokens(integer) FROM anon;
REVOKE ALL ON FUNCTION public.log_ai_global_tokens(integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.log_ai_global_tokens(integer) TO service_role;

CREATE FUNCTION public.get_ai_global_tokens_today()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT total_tokens FROM public.ai_global_usage WHERE usage_date = CURRENT_DATE),
    0
  );
$$;

REVOKE ALL ON FUNCTION public.get_ai_global_tokens_today() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_ai_global_tokens_today() FROM anon;
REVOKE ALL ON FUNCTION public.get_ai_global_tokens_today() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_ai_global_tokens_today() TO service_role;
