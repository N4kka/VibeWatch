-- F0.c.1 — weekly-content-curator scrive su `discovery_content`, una tabella
-- che non esiste: fallisce ogni domenica da quando e' stato creato. Qui si
-- toglie la schedule; la edge function e' stata cancellata a parte
-- (`supabase functions delete weekly-content-curator`).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'weekly-content-curator') THEN
    PERFORM cron.unschedule('weekly-content-curator');
  END IF;
END $$;

-- F0.c.2 — overload ambigui delle RPC clip.
--
-- Ogni coppia condivide gli stessi nomi di parametro, quindi PostgREST non puo'
-- scegliere e risponde 300. Il dato lo conferma: clip_reactions ha 0 righe da
-- sempre e clip_comment_likes pure — i like ai clip non hanno mai raggiunto il
-- server.
--
-- Si tengono le varianti TEXT perche' sono quelle che iOS sa decodificare:
-- restituiscono TABLE(liked boolean, like_count integer), che e' esattamente la
-- forma di SupabaseToggleClipLikeResponse / SupabaseToggleCommentLikeResponse
-- (ClipCommentService.swift:481-484, 513-516). Le varianti UUID restituiscono
-- jsonb e non corrispondono a nessuna struct del client.
--
-- Effetto collaterale voluto: tolta l'ambiguita', i like ai clip iniziano a
-- funzionare lato server anche per il parco installato v2.7/v2.8.
DROP FUNCTION IF EXISTS public.clip_toggle_reaction(text, uuid);
DROP FUNCTION IF EXISTS public.clip_toggle_comment_like(uuid, uuid);
DROP FUNCTION IF EXISTS public.clip_add_comment(text, text, uuid, uuid);

-- clip_delete_comment(uuid) e' overload singolo: resta com'e'.

-- Verifica: dopo il drop nessun nome deve avere piu' di una firma, altrimenti
-- l'ambiguita' resta e la migration va annullata.
DO $$
DECLARE dup text;
BEGIN
  SELECT string_agg(proname, ', ') INTO dup
  FROM (
    SELECT p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('clip_toggle_reaction','clip_toggle_comment_like','clip_add_comment','clip_delete_comment')
    GROUP BY p.proname
    HAVING count(*) > 1
  ) s;
  IF dup IS NOT NULL THEN
    RAISE EXCEPTION 'overload ancora ambigui: % — rollback', dup;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
