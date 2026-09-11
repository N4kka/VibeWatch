-- SPEC v3 §1.5 — il riscaldamento notturno della mappa TVDB->TMDB.
--
-- La mappa e' condivisa: "il primo utente che importa una serie paga; tutti gli altri la trovano
-- gia' risolta". Il problema e' quanto paga il primo — 21.189 episodi su un export reale, una
-- `/find` ciascuno (§6, e dedurre la corrispondenza dai numeri e' proprio cio' che la spec vieta).
--
-- Questo job sposta il costo dove non lo aspetta nessuno. Alle 03:30 UTC prende la coda che gli
-- import hanno lasciato indietro — id in `import_staging` ancora `pending` e assenti dalla mappa —
-- e la risolve con un budget suo, sotto quello degli import: se il tetto globale e' conteso deve
-- perdere il lavoro che nessuno sta guardando, non l'import di una persona davanti alla barra.
--
-- 03:30 e non 05:00: `refresh-backlog` gira alle 05:00 e non conviene sovrapporre due lavori che
-- toccano lo stesso catalogo.

select cron.schedule(
  'catalog-prewarm',
  '30 3 * * *',
  $$
  select net.http_post(
    url := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/catalog-prewarm',
    headers := jsonb_build_object(
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      -- `catalog-prewarm` controlla l'Authorization da se': e' l'unica cosa che distingue il
      -- riscaldamento da una chiamata qualunque, e senza non parte.
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key'),
      'Content-Type', 'application/json'),
    body := '{}'::jsonb);
  $$
);
