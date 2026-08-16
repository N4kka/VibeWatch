-- F0.d-bis.2 — movie_reaction_counts da tabella a vista aggregata.
--
-- Entrambe le tabelle sono a 0 righe, nessun lettore server-side, e iOS legge
-- solo la propria copia SQLite (MovieReactionService.swift) senza piu' spingere
-- i conteggi. La vista e' deliberatamente esclusa dal pull (SyncEngine.swift:863).
--
-- La vista NON deve essere security_invoker: la RLS di movie_reactions e'
-- per-proprietario, e con l'invoker un contatore globale diventerebbe il
-- contatore personale di chi guarda. Il default di Postgres e' gia' quello
-- giusto, ma va detto perche' e' l'unico motivo per cui resta cosi'.
DROP TRIGGER IF EXISTS trg_movie_reactions_counts ON public.movie_reactions;
DROP TABLE public.movie_reaction_counts;
DROP FUNCTION public.refresh_movie_reaction_counts();

CREATE VIEW public.movie_reaction_counts AS
SELECT r.media_id,
       r.media_type,
       count(*) FILTER (WHERE r.reaction_type = 'like'    AND r.deleted_at IS NULL)::integer AS like_count,
       count(*) FILTER (WHERE r.reaction_type = 'dislike' AND r.deleted_at IS NULL)::integer AS dislike_count,
       max(r.updated_at) AS updated_at
  FROM public.movie_reactions r
 GROUP BY r.media_id, r.media_type;

GRANT SELECT ON public.movie_reaction_counts TO anon, authenticated;
COMMENT ON VIEW public.movie_reaction_counts IS
  'Aggregato globale su movie_reactions. NON impostare security_invoker: la RLS di movie_reactions e'' per-proprietario e trasformerebbe il contatore globale in un contatore personale.';

-- F0.d-bis.4 — ai_global_usage confluisce in api_proxy_budget.
-- I token giornalieri stanno sull'ordine delle decine di migliaia: `call_count`
-- e' integer e non rischia overflow.
ALTER TABLE public.api_proxy_budget DROP CONSTRAINT api_proxy_budget_provider_check;
ALTER TABLE public.api_proxy_budget ADD CONSTRAINT api_proxy_budget_provider_check
  CHECK (provider = ANY (ARRAY['youtube','streaming_availability','tmdb','auth_login','cerebras']));

INSERT INTO public.api_proxy_budget (provider, scope, window_start, call_count, updated_at)
SELECT 'cerebras', 'global:tokens', u.usage_date::timestamptz, u.total_tokens::integer, u.last_updated
  FROM public.ai_global_usage u
ON CONFLICT (provider, scope, window_start) DO UPDATE
  SET call_count = EXCLUDED.call_count, updated_at = EXCLUDED.updated_at;

CREATE OR REPLACE FUNCTION public.log_ai_global_tokens(p_tokens integer)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  new_total bigint;
BEGIN
  IF p_tokens IS NULL OR p_tokens < 0 THEN
    RAISE EXCEPTION 'log_ai_global_tokens: p_tokens must be a non-negative integer';
  END IF;

  INSERT INTO public.api_proxy_budget (provider, scope, window_start, call_count, updated_at)
  VALUES ('cerebras', 'global:tokens', CURRENT_DATE::timestamptz, p_tokens, now())
  ON CONFLICT (provider, scope, window_start)
  DO UPDATE SET
    call_count = public.api_proxy_budget.call_count + EXCLUDED.call_count,
    updated_at = now()
  RETURNING call_count INTO new_total;

  RETURN new_total;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_ai_global_tokens_today()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT call_count FROM public.api_proxy_budget
      WHERE provider = 'cerebras' AND scope = 'global:tokens'
        AND window_start = CURRENT_DATE::timestamptz),
    0
  )::bigint;
$function$;

DROP TABLE public.ai_global_usage;

-- F0.d-bis.7 — clips.language e' popolata al 100% ma invisibile al client, che
-- decodifica solo language_code (Clip.swift:42), NULL nel 60% dei casi.
-- Si travasa, tenendo language_code dove entrambe esistono: i 2 casi in
-- conflitto si risolvono a favore di quella che il client gia' legge.
UPDATE public.clips SET language_code = language WHERE language_code IS NULL AND language IS NOT NULL;
ALTER TABLE public.clips DROP COLUMN language;

-- discovery_cache: le righe sono tutte scadute. La tabella resta (iOS la
-- interroga ancora all'avvio dentro un do/catch tollerante); il DROP e' gated v2.9.
DELETE FROM public.discovery_cache WHERE expires_at < now();

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM public.clips WHERE language_code IS NULL;
  IF n > 0 THEN
    RAISE EXCEPTION 'restano % clip senza language_code dopo il backfill — rollback', n;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
