# Blocco 3 — Eventi di visione e stato per serie

> SPEC v3 §1.1, §1.2, §3.2-§3.5. Aggiornato: 2026-07-31. **Non ancora deployato.**

## Cosa contiene

| Migration | Cosa fa |
|---|---|
| `20260730010000_create_watch_events.sql` | La tabella di eventi, con l'indice unico su `dedup_key` che rende l'import idempotente |
| `20260730020000_create_tv_show_state.sql` | Stato derivato, `recompute_tv_show_state()`, trigger, bucket, vista `v_tv_tracking`, job `refresh-backlog` |
| `20260730030000_drop_legacy_tv_tracking.sql` | Via `tv_tracking`, `tv_episode_progress`, `v_tv_tracking_buckets`, `get_tv_tracking_buckets()` |

Più l'harness SQL: `supabase/tests/run.sh` crea un PostgreSQL usa-e-getta, applica le migration
**due volte** (una migration deve poter essere riapplicata) ed esegue `tracking_test.sql`.
**59 asserzioni, tutte verdi.** Non tocca nessun database esistente e non lascia servizi attivi.

## I criteri di accettazione di §13 coperti dai test

| # | Criterio | Come è verificato |
|---:|---|---|
| 2 | Reimportare lo stesso ZIP non duplica | Lo stesso `dedup_key` viene rifiutato dall'indice unico; due utenti diversi possono averlo uguale |
| 3 | Un episodio non ancora uscito non è mai il prossimo da vedere | `is_next_available = false` e `backlog_since = null` quando resta solo S2E2 che esce fra una settimana |
| 4 | Segnare visto l'ultimo pendente fa risalire la serie subito | Dopo l'evento: `next` avanza, `backlog_since` = adesso, bucket `up_next` |
| 5 | Una serie con un buco vecchio non risale per una stagione nuova | 9/10 visti 6 mesi fa: `next` resta S1E10, `backlog_since` resta a 6 mesi fa, bucket `stale` |

Coperti anche: rewatch che non gonfia il progresso, speciali dentro/fuori dal denominatore secondo
la preferenza, cancellazione soft che riporta indietro lo stato, i sette bucket di §3.4, l'isolamento
RLS fra due utenti, e il job giornaliero che riporta in arretrato una serie senza che l'utente
faccia niente.

## Decisioni prese qui, che la spec non fissava

- **Il trigger è a livello di statement, non di riga.** §3.5 dice `after insert or update of
  deleted_at`, e per riga sarebbe letterale — ma l'import scrive 20.000 eventi su ~430 serie, cioè
  20.000 ricalcoli invece di 430. Con le transition table il risultato è identico e il costo no.
  Nota: Postgres **non ammette** `after update of deleted_at` insieme a una transition table
  ("transition tables cannot be specified for triggers with column lists"), quindi il filtro sulla
  colonna si fa dentro la funzione confrontando le due tabelle di transizione — così l'update di
  `synced_at` che il sync fa a ogni push non ricalcola niente. L'ha trovato l'harness al primo giro.
- **`next_season/next_episode/next_air_date` puntano al primo episodio non visto anche se non è
  ancora uscito.** Serve alla timeline delle uscite (§9.2), che altrimenti non avrebbe da dove
  leggere la data. Chi decide se è già guardabile è `is_next_available` nella vista, e
  `backlog_since` continua a considerare solo ciò che è uscito: il criterio 3 resta soddisfatto.
- **`watched_count` conta gli episodi distinti negli eventi, anche quelli che il catalogo non
  conosce.** Gli eventi sono la verità su cosa l'utente ha visto; l'oracolo documenta 31 serie su
  430 in cui le numerazioni divergono, e scartarle silenziosamente significherebbe cancellare pezzi
  di cronologia di qualcuno per far tornare una barra di progresso.
- **Grant per colonna su `tv_show_state`.** La RLS dice quali righe, i grant dicono quali campi:
  il client può scrivere solo `user_status` (che è una sua scelta) e non i derivati. Senza,
  qualunque client potrebbe scriversi `watched_count = 9999` — cioè esattamente il dato che §1.1
  sposta sul server.
- **Il job giornaliero filtra su `current_date + 1`, non `current_date`.** Gira sull'orologio del
  server (UTC) ma il ricalcolo decide con `user_today`, che per un utente a UTC+14 è già il giorno
  dopo: senza il margine chi vive a est vedrebbe l'episodio nuovo con 24 ore di ritardo.
- **Il fuso dell'utente arriva da `user_notification_preferences.timezone`**, la colonna che
  `process-notifications` usa già per le quiet hours. Nessuna colonna nuova. Se manca o è invalida
  si ricade su UTC invece di far fallire il ricalcolo — ed è testato.

## Cosa serve per deployare

1. Applicare le migration nell'ordine dei file. La `030000` **droppa** quattro oggetti: hanno 0
   righe, 0 scrittori e 0 lettori (nessun riferimento nel codice Swift, verificato; `episode-radar`
   e `continue-watching-reminder` leggono `list_items`), ma è comunque l'unica irreversibile del
   blocco — vale la pena guardarla prima di lanciarla.
2. Riavviare PostgREST (Settings → API) per la schema cache.
3. Verificare che il job ci sia: `select jobname, schedule from cron.job where jobname = 'refresh-backlog'`.
   La migration lo crea solo se `pg_cron` è installata (in produzione c'è, 1.6.4).

## Cosa manca ancora

- **La paginazione del pull (blocco 4)**, che va fatta *prima* di far arrivare `watch_events` sul
  client: un utente importato da TV Time porta 20.000 righe e oggi il pull fa `SELECT *` senza
  `range()`.
- L'integrazione client (blocco 5): mirror SQLite, whitelist, outbox, pull-list, strategie di
  conflitto di §4.
- `count_specials_in_progress` esiste su `unified_user_preferences` ma nessuna UI la espone: è
  lettura sola per il ricalcolo finché non arriva il blocco 7.
