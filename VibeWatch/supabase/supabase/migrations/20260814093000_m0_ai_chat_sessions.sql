-- M0 — `ai_chat_sessions`: titolo e pin delle conversazioni AI.
--
-- Su iOS questi due dati vivono in UserDefaults, quindi non seguono l'utente da
-- un dispositivo all'altro. La web app li promuove a dati sincronizzati.
--
-- SCOSTAMENTO DAL PIANO: il piano dichiarava `id uuid`. Ma la chiave di sessione
-- esiste gia' ed e' `ai_conversation_history.session_id`, che e' `text`. Con un
-- uuid qui ogni join fra le due tabelle avrebbe richiesto un cast, e il client
-- avrebbe dovuto garantire che le sue chiavi di sessione fossero uuid — cosa che
-- oggi non fa. `id text` si lega direttamente allo spazio di chiavi che c'e'.

CREATE TABLE public.ai_chat_sessions (
  id         text PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title      text,
  pinned     boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.ai_chat_sessions IS
  'Titolo e pin per sessione di chat AI. `id` combacia con ai_conversation_history.session_id (text, non uuid).';

-- L'elenco sessioni si legge sempre per utente e ordinato per recenza.
CREATE INDEX ai_chat_sessions_user_updated_idx
  ON public.ai_chat_sessions (user_id, updated_at DESC);

ALTER TABLE public.ai_chat_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY ai_chat_sessions_own_rows
  ON public.ai_chat_sessions
  FOR ALL
  TO authenticated
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

-- Esplicito invece di affidarsi ai default: anon non ha niente da fare qui.
REVOKE ALL ON public.ai_chat_sessions FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_chat_sessions TO authenticated;

CREATE TRIGGER ai_chat_sessions_set_updated_at
  BEFORE UPDATE ON public.ai_chat_sessions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Ramo in apply_mutations.
--
-- Non si riscrive la funzione per intero: e' lunga qualche centinaio di righe e
-- ricopiarla a mano per aggiungere un ramo e' il modo classico di perdere per
-- strada una riga di un'altra tabella. Si prende la definizione viva, si inserisce
-- il ramo prima di quello di `ai_conversation_history`, e si riesegue. La guardia
-- fa fallire la migration se il punto di innesto non c'e' piu'.
DO $mig$
DECLARE
  src text;
  needle constant text := '      elsif tbl = ''ai_conversation_history'' then';
  branch constant text := $branch$      elsif tbl = 'ai_chat_sessions' then
        if v_write then
          if coalesce(rec_id, '') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            insert into public.ai_chat_sessions as t
              (id, user_id, title, pinned, created_at, updated_at)
            values
              (rec_id, v_uid, nullif(rec->>'title', ''),
               coalesce(nullif(rec->>'pinned', '')::boolean, false),
               coalesce(nullif(rec->>'created_at', '')::timestamptz, now()),
               coalesce(nullif(rec->>'updated_at', '')::timestamptz, now()))
            on conflict (id) do update set
              title = excluded.title,
              pinned = excluded.pinned,
              updated_at = excluded.updated_at
            -- La chiave e' testuale e la sceglie il client: senza questo filtro
            -- due utenti che generano la stessa stringa si sovrascriverebbero.
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          delete from public.ai_chat_sessions where id = rec_id and user_id = v_uid;
        end if;

$branch$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'apply_mutations';

  IF src IS NULL THEN
    RAISE EXCEPTION 'apply_mutations non trovata';
  END IF;
  IF position('ai_chat_sessions' in src) > 0 THEN
    RAISE NOTICE 'ramo ai_chat_sessions gia'' presente, niente da fare';
    RETURN;
  END IF;
  IF position(needle in src) = 0 THEN
    RAISE EXCEPTION 'punto di innesto non trovato in apply_mutations — rollback';
  END IF;

  EXECUTE replace(src, needle, branch || needle);
END $mig$;

-- Prova che il ramo sia davvero dentro.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'apply_mutations'
       AND pg_get_functiondef(p.oid) LIKE '%ai_chat_sessions%'
  ) THEN
    RAISE EXCEPTION 'il ramo ai_chat_sessions non risulta in apply_mutations — rollback';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
