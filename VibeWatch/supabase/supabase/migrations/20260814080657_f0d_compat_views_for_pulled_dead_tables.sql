-- F0.d.4 + F0.d-bis.1 + F0.d-bis.5 — tre tabelle morte che il client pero'
-- continua a scaricare.
--
-- Perche' viste e non DROP secco: SyncEngine le ha nella lista di pull
-- (SyncEngine.swift:846-887). Se sparissero, PostgREST risponderebbe PGRST205 e
-- ogni sync finirebbe in failSync(.partialFailure), fermando gli aggiornamenti
-- di UI dopo il pull su tutto il parco installato v2.7/v2.8. Una vista sempre
-- vuota con la stessa forma risponde 200 con 0 righe, che e' esattamente cio'
-- che quelle tabelle gia' restituivano.
--
-- Verificato che nessuna delle tre abbia un ramo in apply_mutations: nessun
-- percorso di scrittura si rompe.
--
--   user_preferences  (0 righe, deprecata)   -> sopravvive unified_user_preferences
--   user_clip_history (0 righe, strutturalmente bloccata: nessun ramo in
--                      apply_mutations, e la sua FK uuid non e' mai stata
--                      compatibile con i clip id testuali del client)
--                                            -> sopravvive user_clip_signals
--   device_info       (0 righe, nessuno scrittore remoto)
--                                            -> sopravvive user_devices

DROP TABLE public.user_preferences;
CREATE VIEW public.user_preferences AS
SELECT NULL::uuid        AS id,
       NULL::uuid        AS user_id,
       NULL::text        AS device_id,
       NULL::text        AS preference_type,
       NULL::text        AS preference_id,
       NULL::text        AS preference_name,
       NULL::double precision AS score,
       NULL::timestamptz AS updated_at,
       NULL::timestamptz AS deleted_at,
       NULL::timestamptz AS synced_at
WHERE false;
GRANT SELECT ON public.user_preferences TO authenticated, anon;
COMMENT ON VIEW public.user_preferences IS
  'Guscio di compatibilita'': la tabella e'' stata eliminata in F0.d. Resta perche'' iOS <= v2.8 la include nel pull e un 404 manderebbe il sync in partialFailure. Sostituita da unified_user_preferences.';

DROP TABLE public.user_clip_history;
CREATE VIEW public.user_clip_history AS
SELECT NULL::uuid        AS id,
       NULL::uuid        AS user_id,
       NULL::text        AS device_id,
       NULL::uuid        AS clip_id,
       NULL::timestamptz AS watched_at,
       NULL::double precision AS watch_duration,
       NULL::double precision AS total_duration,
       NULL::double precision AS completion_rate,
       NULL::boolean     AS liked,
       NULL::boolean     AS commented,
       NULL::boolean     AS shared,
       NULL::boolean     AS added_to_list,
       NULL::double precision AS engagement_score,
       NULL::timestamptz AS deleted_at,
       NULL::timestamptz AS synced_at
WHERE false;
GRANT SELECT ON public.user_clip_history TO authenticated, anon;
COMMENT ON VIEW public.user_clip_history IS
  'Guscio di compatibilita'': la tabella e'' stata eliminata in F0.d. Era gia'' bloccata a 0 righe (nessun ramo in apply_mutations, ogni push finiva in sync_rejected_mutations). Sostituita da user_clip_signals.';

DROP TABLE public.device_info;
CREATE VIEW public.device_info AS
SELECT NULL::text        AS device_id,
       NULL::uuid        AS user_id,
       NULL::text        AS device_name,
       NULL::text        AS device_type,
       NULL::text        AS app_version,
       NULL::timestamptz AS last_sync_at,
       NULL::timestamptz AS last_active_at,
       NULL::timestamptz AS created_at
WHERE false;
GRANT SELECT ON public.device_info TO authenticated, anon;
COMMENT ON VIEW public.device_info IS
  'Guscio di compatibilita'': la tabella e'' stata eliminata in F0.d. Non ha mai avuto uno scrittore remoto — tutti i riferimenti Swift sono a SQLite locale. Sostituita da user_devices.';

NOTIFY pgrst, 'reload schema';
