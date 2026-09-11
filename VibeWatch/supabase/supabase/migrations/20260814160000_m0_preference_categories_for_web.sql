-- M0 — le due categorie di preferenze che la web app promuove a dato sincronizzato.
--
-- Il piano dava per scontato che bastasse scriverle: «selected platforms and
-- recent-visited as unified_user_preferences rows (categories selected_platform,
-- recent_visited) — already whitelisted, zero new RLS». La RLS in effetti va
-- bene e apply_mutations ha gia' il suo ramo, ma c'e' un CHECK che il piano non
-- cita e che le rifiuta entrambe:
--
--   CHECK (preference_category IN ('genre','actor','director','mood','keyword'))
--
-- Scoperto provando davvero una scrittura: constraint_23514 in
-- sync_rejected_mutations. Senza questa migration, la selezione delle
-- piattaforme e i "visti di recente" sarebbero falliti in silenzio — la coda di
-- mutazioni scarta la riga e va avanti.
ALTER TABLE public.unified_user_preferences
  DROP CONSTRAINT unified_user_preferences_preference_category_check;

ALTER TABLE public.unified_user_preferences
  ADD CONSTRAINT unified_user_preferences_preference_category_check
  CHECK (preference_category = ANY (ARRAY[
    -- Categorie con punteggio, alimentate dalla personalizzazione.
    'genre', 'actor', 'director', 'mood', 'keyword',
    -- Categorie senza punteggio, promosse da device-local a sincronizzate (web).
    'selected_platform', 'recent_visited'
  ]));

-- Il decadimento settimanale ha senso solo per le categorie con punteggio.
-- Sulle altre non farebbe danno (il punteggio e' NULL), ma toccherebbe
-- `updated_at` ogni lunedi' su righe che non sono cambiate — e un timestamp che
-- si muove da solo e' esattamente cio' che rende inservibile un last-write-wins.
CREATE OR REPLACE FUNCTION public.decay_preference_scores(p_user_id uuid, p_decay_rate real DEFAULT 0.95)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    affected_count INTEGER;
BEGIN
    UPDATE public.unified_user_preferences
    SET
        score = score * p_decay_rate,
        score_from_clips = score_from_clips * p_decay_rate,
        score_from_discovery = score_from_discovery * p_decay_rate,
        score_from_search = score_from_search * p_decay_rate,
        score_from_ai = score_from_ai * p_decay_rate,
        score_from_lists = score_from_lists * p_decay_rate,
        last_decay_at = NOW(),
        updated_at = NOW()
    WHERE user_id = p_user_id
        AND preference_category IN ('genre', 'actor', 'director', 'mood', 'keyword')
        AND (last_decay_at IS NULL OR last_decay_at < NOW() - INTERVAL '7 days');

    GET DIAGNOSTICS affected_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'decayed_count', affected_count,
        'decay_rate', p_decay_rate
    );
END;
$function$;

DO $$
DECLARE u uuid; ok boolean;
BEGIN
  SELECT id INTO u FROM public.profiles WHERE deleted_at IS NULL LIMIT 1;
  BEGIN
    INSERT INTO public.unified_user_preferences
      (id, user_id, device_id, preference_category, preference_id, preference_name)
    VALUES (gen_random_uuid(), u, 'verifica', 'selected_platform', '8', 'Netflix');
    INSERT INTO public.unified_user_preferences
      (id, user_id, device_id, preference_category, preference_id, preference_name)
    VALUES (gen_random_uuid(), u, 'verifica', 'recent_visited', 'movie:550', 'Fight Club');
    ok := true;
  EXCEPTION WHEN check_violation THEN
    ok := false;
  END;
  IF NOT ok THEN
    RAISE EXCEPTION 'le nuove categorie sono ancora rifiutate dal CHECK — rollback';
  END IF;
  -- Le righe di prova non restano: erano solo la prova.
  DELETE FROM public.unified_user_preferences WHERE device_id = 'verifica';
END $$;
