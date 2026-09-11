-- HOTFIX 2 — Tracking/watchlist vuoti, e commenti ai clip in 404.

-- ---------------------------------------------------------------------------
-- 1. `user_today`: Tracking e watchlist serie TV erano vuoti.
--
-- COSA HO SBAGLIATO. In F0.b.6 ho revocato l'EXECUTE ad `authenticated`
-- seguendo il piano, che diceva «serve solo ai chiamanti interni». Non e' vero:
-- `v_tv_tracking` e `v_tv_timeline` sono viste **security_invoker** e la
-- chiamano dentro la propria definizione. Con security_invoker la funzione gira
-- come il ruolo che interroga — `authenticated` — che non aveva piu' il
-- permesso. Postgres rispondeva "permission denied for function user_today",
-- PostgREST lo traduceva in 403, e il client mostrava zero serie.
--
-- I dati non sono mai stati toccati: tv_show_state 1915 righe, v_tv_tracking
-- 1915, watch_events 109.451. Era solo la lettura a essere chiusa.
--
-- Invece di rimettere semplicemente il grant (che riaprirebbe la IDOR che F0.b.6
-- voleva chiudere: chiunque poteva chiedere il fuso di un altro utente), la
-- funzione ora preferisce auth.uid() quando c'e' una sessione, e usa il
-- parametro solo quando non c'e' — cioe' per i chiamanti interni.
--
-- Verificato su tutti e 5 i chiamanti, e per ognuno il comportamento resta
-- identico perche' il parametro coincide sempre con il chiamante:
--   v_tv_tracking, v_tv_timeline      -> la RLS limita alle righe proprie
--   expand_seen_shows_to_watch_events -> definer, invocata dall'utente per se'
--   recompute_tv_show_state           -> da trigger sulle scritture del proprietario
--   refresh_backlog_since             -> da cron, auth.uid() e' NULL -> parametro
CREATE OR REPLACE FUNCTION public.user_today(p_user_id uuid)
 RETURNS date
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_timezone text;
  v_user uuid := coalesce(auth.uid(), p_user_id);
begin
  select nullif(timezone, '') into v_timezone
  from public.user_notification_preferences where user_id = v_user;
  return (now() at time zone coalesce(v_timezone, 'UTC'))::date;
exception when others then
  return (now() at time zone 'UTC')::date;
end $function$;

GRANT EXECUTE ON FUNCTION public.user_today(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. `clip_add_comment`: 404 da PostgREST.
--
-- Questo NON e' una regressione di F0 — non ha mai funzionato per i commenti di
-- primo livello. Il payload Swift e':
--
--   struct SupabaseAddCommentPayload {
--     let p_clip_id: String
--     let p_content: String
--     let p_parent_comment_id: String?   <-- opzionale
--     let p_comment_id: String
--   }
--
-- La conformita' Codable sintetizzata da Swift usa `encodeIfPresent` per le
-- proprieta' opzionali: quando il commento non e' una risposta, la chiave
-- `p_parent_comment_id` **non viene inviata affatto**. PostgREST cerca allora
-- una funzione a tre argomenti, non la trova e risponde 404. Solo le risposte a
-- un commento esistente potevano funzionare.
--
-- Bastano i DEFAULT: la chiamata a 3 argomenti si risolve, quella a 4 continua a
-- funzionare identica. In PostgreSQL i default devono essere in coda, quindi ne
-- prende uno anche p_comment_id — che il corpo gia' sa gestire, generando un
-- uuid quando il valore non e' utilizzabile.
CREATE OR REPLACE FUNCTION public.clip_add_comment(
  p_clip_id text,
  p_content text,
  p_parent_comment_id text DEFAULT NULL,
  p_comment_id text DEFAULT NULL
)
 RETURNS clip_comments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  inserted_row clip_comments;
  v_id uuid;
  v_parent uuid;
BEGIN
  v_id := CASE
    WHEN p_comment_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN p_comment_id::uuid
    ELSE gen_random_uuid()
  END;

  IF NULLIF(p_parent_comment_id, '') IS NOT NULL THEN
    IF p_parent_comment_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'clip_add_comment: p_parent_comment_id non e'' un uuid valido';
    END IF;
    v_parent := p_parent_comment_id::uuid;
  END IF;

  -- clips.comments e clip_comments.reply_count li aggiornano i trigger.
  INSERT INTO clip_comments (
    id, clip_id, user_id, parent_comment_id, content,
    like_count, reply_count, created_at, updated_at
  )
  VALUES (
    v_id, p_clip_id, auth.uid(), v_parent, p_content,
    0, 0, timezone('utc', now()), timezone('utc', now())
  )
  RETURNING * INTO inserted_row;

  RETURN inserted_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.clip_add_comment(text, text, text, text) TO authenticated, service_role;

DO $$
DECLARE n integer;
BEGIN
  -- Un solo overload: due significherebbero di nuovo 300 da PostgREST.
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'clip_add_comment';
  IF n <> 1 THEN
    RAISE EXCEPTION 'clip_add_comment ha % firme, attesa 1 — rollback', n;
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.user_today(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated non puo'' ancora eseguire user_today — rollback';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
