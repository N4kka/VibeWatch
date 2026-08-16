-- `list_milestone` e `price_drop`: due preferenze senza produttore, mai usate per inviare una
-- notifica. Il dispatcher, il vincolo CHECK e le app le avevano già dimenticate nella migration
-- 20260815101000; a tenerle in vita era la base installata, perché l'app scrive le preferenze
-- via PostgREST con la lista esplicita delle colonne e PostgREST rifiuta l'intero payload se
-- una colonna non esiste. Toglierle con una build vecchia in circolazione non avrebbe ignorato
-- due interruttori morti: avrebbe fatto fallire ogni modifica alle preferenze di quegli utenti
-- (quiet hours, notifiche social, push on/off comprese), e il client si limita a loggarlo.
--
-- Applicata il 2026-08-16, dopo aver portato `update.json` a `minimum_version: 2.8`: la 2.8 è la
-- prima build che non le invia più, e il blocco di aggiornamento non è chiudibile
-- (`UpdateRequiredView`, `interactiveDismissDisabled`), quindi nessun client che le manda può
-- più raggiungere la tabella. La web app elenca le sue colonne una per una e queste due non le
-- ha mai scritte.
--
-- Prima del drop: 154 righe, `price_drop` vero su 0, `list_milestone` vero su tutte per il
-- default. Nessuna vista, funzione, vincolo o policy le nominava.

alter table public.user_notification_preferences
  drop column if exists price_drop,
  drop column if exists list_milestone;
