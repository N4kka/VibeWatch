-- La rete di sicurezza sotto il webhook di RevenueCat: se un evento si perde, entro
-- ventiquattr'ore lo stato Pro si raddrizza da solo. La funzione esisteva da mesi ma
-- non la chiamava nessuno, ed e' il motivo per cui un webhook muto (verify_jwt = true,
-- corretto il 2026-08-15) non si e' visto: `user_entitlements` restava ferma al backfill
-- del 23 luglio senza che niente lo dicesse.
--
-- Solo demozione: legge le righe con is_pro = true e toglie il Pro a chi RevenueCat
-- dichiara scaduto, mai il contrario. Promuovere resta compito del webhook.
--
-- 03:10 UTC: fra api_proxy_prune (02:10) e catalog-prewarm (03:30), lontano dai picchi.
select cron.schedule(
  'reconcile-pro-status',
  '10 3 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/reconcile-pro-status',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);
