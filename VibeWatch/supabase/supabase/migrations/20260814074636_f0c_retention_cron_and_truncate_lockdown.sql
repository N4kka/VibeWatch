-- F0.c.4 — le funzioni di retention esistevano ma nessun cron le chiamava.
--
-- Escluse di proposito:
--   * cleanup_expired_cache()     -> lavora su media_details_cache e trailers_cache
--   * cleanup_expired_discovery() -> lavora su discovery_warm_feeds
-- Tutte e tre le tabelle vengono eliminate da F0.d.2: le due funzioni si
-- eliminano li', non si schedulano qui.

-- Retention a 90 giorni per i log di notifica. Nessuna delle due tabelle e' nella
-- lista di pull di SyncEngine (verificato: SyncEngine.swift:846-887), quindi la
-- cancellazione lato server non tocca lo storico sul dispositivo dell'utente.
CREATE OR REPLACE FUNCTION public.notifications_retention_sweep(p_older_than interval DEFAULT '90 days')
 RETURNS TABLE(delivery_log_deleted bigint, notifications_deleted bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  n_log bigint;
  n_notif bigint;
BEGIN
  DELETE FROM public.notification_delivery_log
   WHERE delivered_at < now() - p_older_than;
  GET DIAGNOSTICS n_log = ROW_COUNT;

  -- Solo le notifiche gia' inviate: una in attesa di consegna non si tocca,
  -- per vecchia che sia.
  DELETE FROM public.notifications
   WHERE is_sent AND created_at < now() - p_older_than;
  GET DIAGNOSTICS n_notif = ROW_COUNT;

  RETURN QUERY SELECT n_log, n_notif;
END;
$function$;

REVOKE ALL ON FUNCTION public.notifications_retention_sweep(interval) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notifications_retention_sweep(interval) TO service_role;

-- decay_preference_scores e' per-utente (p_user_id, p_decay_rate): da sola non e'
-- schedulabile. Il wrapper cicla sugli utenti che hanno preferenze; la guardia
-- interna della funzione (last_decay_at piu' vecchio di 7 giorni) rende
-- l'operazione idempotente, quindi una passata in piu' non decade nulla due volte.
CREATE OR REPLACE FUNCTION public.decay_all_preference_scores(p_decay_rate real DEFAULT 0.95)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  u uuid;
  n integer := 0;
BEGIN
  FOR u IN SELECT DISTINCT user_id FROM public.unified_user_preferences WHERE user_id IS NOT NULL
  LOOP
    PERFORM public.decay_preference_scores(u, p_decay_rate);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$function$;

REVOKE ALL ON FUNCTION public.decay_all_preference_scores(real) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.decay_all_preference_scores(real) TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'api-proxy-prune')        THEN PERFORM cron.unschedule('api-proxy-prune'); END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'webhook-logs-retention') THEN PERFORM cron.unschedule('webhook-logs-retention'); END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notifications-retention')THEN PERFORM cron.unschedule('notifications-retention'); END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'preference-decay')       THEN PERFORM cron.unschedule('preference-decay'); END IF;

  -- Orari scelti fuori dalla finestra 3:30-7:00, gia' occupata da prewarm,
  -- refresh catalogo, radar e availability.
  PERFORM cron.schedule('api-proxy-prune',         '10 2 * * *',  'select public.api_proxy_prune();');
  PERFORM cron.schedule('notifications-retention', '25 2 * * *',  'select public.notifications_retention_sweep();');
  PERFORM cron.schedule('webhook-logs-retention',  '40 2 * * 1',  'select public.clean_old_webhook_logs();');
  PERFORM cron.schedule('preference-decay',        '55 2 * * 1',  'select public.decay_all_preference_scores();');
END $$;

-- Fuori dal piano, approvato a parte: anon e authenticated avevano TRUNCATE,
-- TRIGGER e REFERENCES su tutte le tabelle di public (default di Supabase).
-- TRUNCATE non e' filtrato dalla RLS — svuoterebbe una tabella nonostante ogni
-- policy. PostgREST non sa emetterlo, quindi serviva una connessione diretta,
-- ma non c'e' motivo per cui quel privilegio esista. SELECT/INSERT/UPDATE/DELETE
-- restano intatti: e' la RLS a governarli.
REVOKE TRUNCATE, TRIGGER, REFERENCES ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

-- E le tabelle future non devono piu' ereditarli.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLES FROM anon, authenticated;
