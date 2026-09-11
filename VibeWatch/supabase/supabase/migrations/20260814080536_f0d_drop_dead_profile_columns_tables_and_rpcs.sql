-- F0.d.1 — 12 colonne di profiles senza lettori.
--
-- Sicuro perche' il pull iOS fa `select("*")` (SyncEngine.swift:930) e tollera
-- che una colonna sparisca. Verificato uno per uno: nessun riferimento in Swift,
-- edge function, corpo di funzione, vista, policy o cron.
--
--   is_founding_member / founding_member_product_id -> 0 founding member esistenti
--   is_on_trial, trial_*                            -> i trial vivono in RevenueCat
--   fcm_token                                       -> sostituito da user_devices.fcm_token
--                                                      (register_user_device e
--                                                      process-notifications leggono quella)
--   has_billing_issue / billing_issue_detected_at   -> 7 righe true mai lette, perdita approvata
--   daily_clips_watched / last_clip_date            -> handle_new_user non le scrive piu' (F0.c.6)
--   subscription_canceled_at                        -> sostituita da user_entitlements.canceled_at,
--                                                      webhook gia' ripuntato e rideployato
ALTER TABLE public.profiles
  DROP COLUMN is_founding_member,
  DROP COLUMN founding_member_product_id,
  DROP COLUMN is_on_trial,
  DROP COLUMN trial_started_at,
  DROP COLUMN trial_cancelled_at,
  DROP COLUMN trial_converted_at,
  DROP COLUMN fcm_token,
  DROP COLUMN has_billing_issue,
  DROP COLUMN billing_issue_detected_at,
  DROP COLUMN daily_clips_watched,
  DROP COLUMN last_clip_date,
  DROP COLUMN subscription_canceled_at;

-- F0.d.2 — 5 tabelle senza righe e senza riferimenti remoti.
--
-- ATTENZIONE ai nomi: personalized_discovery (49 occorrenze), media_details_cache
-- e trailers_cache esistono ANCHE come tabelle SQLite locali nell'app iOS
-- (SQLiteSchema.swift). Sono omonime e scollegate: nessuna `.from()` remota le
-- tocca. Quelle locali non vengono sfiorate da qui.
--
-- list_reports NON si tocca, malgrado 0 righe: e' viva (get_activity_feed,
-- apply_mutations, get_public_lists, get_list_items_with_providers).
DROP TABLE public.discovery_warm_feeds;
DROP TABLE public.personalized_discovery;
DROP TABLE public.media_details_cache;
DROP TABLE public.trailers_cache;
DROP TABLE public.health_check;

-- Le due funzioni di pulizia restano orfane con le loro tabelle: si eliminano
-- qui invece di schedularle (F0.c.4).
DROP FUNCTION public.cleanup_expired_cache();
DROP FUNCTION public.cleanup_expired_discovery();

-- F0.d.3 — 9 RPC senza un solo chiamante, verificato su Swift, edge function,
-- corpi di funzione e cron.
DROP FUNCTION public.get_user_profile_summary(uuid);
DROP FUNCTION public.get_personalized_recommendations(uuid, integer);
DROP FUNCTION public.log_ai_token_usage(uuid, integer);
DROP FUNCTION public.increment_clip_views(uuid);
DROP FUNCTION public.reset_daily_quotas();
DROP FUNCTION public.calculate_quality_score(integer, double precision, integer);
DROP FUNCTION public.create_default_lists();
DROP FUNCTION public.backfill_watchlist_tracking();
DROP FUNCTION public.suggest_username(text, text);

NOTIFY pgrst, 'reload schema';
