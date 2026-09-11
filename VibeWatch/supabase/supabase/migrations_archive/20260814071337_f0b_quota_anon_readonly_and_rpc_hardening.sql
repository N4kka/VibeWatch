-- F0.b.5 — user_daily_quota: la policy anon era FOR ALL con predicato
-- (user_id IS NULL AND device_id IS NOT NULL), quindi un qualsiasi chiamante
-- anonimo poteva riscrivere tutte le 381 righe di quota anonime. Si restringe a
-- SELECT. I due writer iOS anonimi (DailyQuotaManager.swift:304,
-- ClipQuotaService.swift:229) fanno l'upsert dentro un do/catch che si limita a
-- loggare un warning: il fallimento degrada in silenzio e la quota resta quella
-- locale. La quota e' comunque advisory.
DROP POLICY IF EXISTS "Anonymous device rows are device-scoped only" ON public.user_daily_quota;
CREATE POLICY "Anonymous device rows are readable only"
  ON public.user_daily_quota
  FOR SELECT
  TO anon
  USING (user_id IS NULL AND device_id IS NOT NULL);

-- F0.b.6 — RPC con p_user_id vestigiale.
--
-- ATTENZIONE: il piano diceva di ignorare il parametro e usare auth.uid() sempre.
-- Non e' applicabile a log_ai_request_usage: il chiamante e' cerebras-proxy con
-- il client admin (cerebras-proxy/index.ts:146), dove auth.uid() e' NULL —
-- forzarlo azzererebbe tutta la contabilita' delle richieste AI.
-- Si chiude invece la IDOR mantenendo il path service_role: con una sessione
-- utente il parametro viene ignorato, senza sessione si accetta solo service_role.
--
-- La versione definitiva del corpo di log_ai_request_usage e' nella migration
-- successiva (20260814071437): qui il rilevamento di service_role era ancora
-- sbagliato.
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
    target_user := auth.uid();
  ELSIF current_setting('request.jwt.claim.role', true) = 'service_role'
     OR current_user = 'service_role' THEN
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

-- reset_ai_token_usage e' chiamato solo da iOS con sessione utente
-- (SupabaseClient.swift:125): qui auth.uid() puo' davvero essere l'unica verita'.
CREATE OR REPLACE FUNCTION public.reset_ai_token_usage(p_user_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  target_user uuid := auth.uid();
BEGIN
  IF target_user IS NULL THEN
    RAISE EXCEPTION 'reset_ai_token_usage: unauthenticated caller';
  END IF;

  INSERT INTO public.user_ai_token_usage (user_id, usage_date, request_count, last_updated)
  VALUES (target_user, CURRENT_DATE, 0, now())
  ON CONFLICT (user_id, usage_date)
  DO UPDATE SET request_count = 0, last_updated = now();

  RETURN 0;
END;
$function$;

-- user_today espone il fuso orario di un altro utente: serve solo ai chiamanti
-- interni, che sono SECURITY DEFINER e non passano dal grant del client.
REVOKE EXECUTE ON FUNCTION public.user_today(uuid) FROM authenticated;

-- Corpi di trigger: nessun ruolo client deve poterli invocare a mano.
REVOKE ALL ON FUNCTION public.touch_import_job() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_movie_reaction_counts() FROM public, anon, authenticated;
