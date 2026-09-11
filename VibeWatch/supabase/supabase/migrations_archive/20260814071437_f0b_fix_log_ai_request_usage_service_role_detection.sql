-- Correzione della migration precedente: dentro una SECURITY DEFINER current_user
-- e' il proprietario (postgres), non il chiamante, e PostgREST recente popola
-- request.jwt.claims (jsonb) e non request.jwt.claim.role. L'unico rilevamento
-- affidabile e' auth.role(), che copre entrambe le forme.
CREATE OR REPLACE FUNCTION public.log_ai_request_usage(p_user_id uuid, p_bucket text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  new_total integer;
  target_user uuid;
BEGIN
  IF p_bucket IS NULL OR p_bucket NOT IN ('chat', 'aux') THEN
    RAISE EXCEPTION 'log_ai_request_usage: p_bucket must be ''chat'' or ''aux''';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    -- Sessione utente: il parametro e' decorativo, conta solo il JWT.
    target_user := auth.uid();
  ELSIF auth.role() = 'service_role' THEN
    -- cerebras-proxy con client admin: e' lui a sapere per chi sta loggando.
    target_user := p_user_id;
  ELSE
    RAISE EXCEPTION 'log_ai_request_usage: unauthenticated caller';
  END IF;

  IF target_user IS NULL THEN
    RAISE EXCEPTION 'log_ai_request_usage: missing user';
  END IF;

  IF p_bucket = 'chat' THEN
    INSERT INTO public.user_ai_token_usage (user_id, usage_date, request_count, last_updated)
    VALUES (target_user, CURRENT_DATE, 1, now())
    ON CONFLICT (user_id, usage_date)
    DO UPDATE SET
      request_count = public.user_ai_token_usage.request_count + 1,
      last_updated = now()
    RETURNING request_count INTO new_total;
  ELSE
    INSERT INTO public.user_ai_token_usage (user_id, usage_date, aux_request_count, last_updated)
    VALUES (target_user, CURRENT_DATE, 1, now())
    ON CONFLICT (user_id, usage_date)
    DO UPDATE SET
      aux_request_count = public.user_ai_token_usage.aux_request_count + 1,
      last_updated = now()
    RETURNING aux_request_count INTO new_total;
  END IF;

  RETURN new_total;
END;
$function$;
