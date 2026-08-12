-- SPEC v3 §7.2 — "L'utente può chiudere l'app: il job prosegue server-side."
--
-- Chi lo fa proseguire è questo cron: ogni minuto invoca `import-driver`, che fa avanzare i job
-- aperti chiamando le funzioni di fase finché il budget di tempo regge. Stesso meccanismo del
-- prewarm (pg_net + chiave dal Vault); la differenza è la guardia `where exists`: con nessun
-- job `running` la SELECT non produce righe e `net.http_post` non viene nemmeno valutata —
-- un cron al minuto che a riposo non fa HTTP.
--
-- NON è nella whitelist di `supabase/tests/run.sh`: il harness non ha né `cron` né `vault`,
-- come già per `20260731160000_catalog_prewarm_cron.sql`.
--
-- `cron.schedule` con lo stesso nome aggiorna il job esistente: la migration è riapplicabile.
--
-- Sta qui (e non in `20260802100000_import_start`) anche il ritocco al CHECK di `notifications`:
-- la tabella precede il repo e nel harness dei test non esiste, come `cron` e `vault`.

-- La push di fine import (§7.2) passa dalla coda `notifications`, e il CHECK sui tipi la
-- rifiuterebbe: `notification_type_check` enumera i tipi ammessi — stessa forma del CHECK di
-- `api_proxy_budget`, ogni tipo nuovo è una migration. Senza questo, l'insert del driver
-- fallirebbe registrato solo nei log: la push mancherebbe e nessuno saprebbe perché.
alter table public.notifications drop constraint if exists notification_type_check;
alter table public.notifications add constraint notification_type_check
  check (notification_type = any (array[
    'new_availability', 'new_release', 'episode_aired', 'continue_watching',
    'list_milestone', 'price_drop', 'streak_reminder', 'import_done']));

select cron.schedule(
  'import-driver',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/import-driver',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      -- `import-driver` accetta solo chiamate col service key (cronAuth): è ciò che lo
      -- distingue da una chiamata qualunque con la publishable key, che è pubblica.
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb)
  where exists (select 1 from public.import_jobs where status = 'running');
  $$
);
