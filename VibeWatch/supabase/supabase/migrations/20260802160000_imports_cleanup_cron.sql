-- SPEC v3 §7.2 — la metà cron del TTL del bucket `imports` (la metà SQL è in
-- 20260802150000_imports_ttl.sql, il perché sta lì).
--
-- Una volta al giorno, alle 04:40 UTC — prima del `refresh-backlog` delle 05:00, così i due
-- non si accavallano mai. Nessuna guardia `where exists` come per `import-driver`: qui la
-- chiamata è UNA al giorno, e deve partire anche quando non c'è niente da cancellare — è la
-- funzione a rispondere `deleted: 0`, e un cron che filtra troppo a monte è un cron che non
-- si accorge di essere rotto.
--
-- NON è nella whitelist di `supabase/tests/run.sh`: il harness non ha né `cron` né `vault`
-- (come `20260802110000_import_driver_cron.sql`). `cron.schedule` con lo stesso nome aggiorna
-- il job esistente: la migration è riapplicabile.

select cron.schedule(
  'imports-cleanup',
  '40 4 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/imports-cleanup',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);
