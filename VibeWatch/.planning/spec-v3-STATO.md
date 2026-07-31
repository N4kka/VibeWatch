# SPEC v3 — stato del lavoro e ripresa

> Aggiornato: 2026-07-31. Branch: `refactoring/spec-v3-prereqs-oracle`.
> Progetto Supabase: `rqhxhkijzhqivljivirq` (VibeWatch, eu-west-1, Postgres 17.6).

## Da fare per prima cosa

**Blocco 5, integrazione client** (SQLite, whitelist, outbox, pull, conflitti). Dipende da 3 e 4,
entrambi chiusi.

Una decisione da prendere lì, lasciata aperta di proposito dal blocco 4: §5 suggerisce di **non
ritirare mai `watch_events` per intero** sul client, ma solo `tv_show_state` (una riga per serie) e
gli eventi degli ultimi N mesi per il diario. Oggi `watch_events` non è ancora nella pull-list, e
`SyncPagination.walk` non sa filtrare: il filtro va aggiunto quando la tabella entra nella lista,
non prima. Con la paginazione in piedi, ritirare 20.000 eventi ora *funziona* — la domanda è se
convenga, non se si possa.

## Stato dei blocchi di §12

| # | Blocco | Stato |
|---|---|---|
| 0 | Prerequisiti P1-P5 | **fatto**, in repo. P2/P3 non verificabili senza un build reale |
| 1 | Oracolo + fixture + harness | **fatto**. 22 test Python verdi, baseline 399/31/37 |
| 2 | Catalogo + `catalog-resolve` | **fatto e in produzione**, verificato end-to-end su Game of Thrones |
| 3 | `watch_events` + `tv_show_state` | **fatto e in produzione**. Harness SQL, 64 asserzioni verdi |
| — | `apply_mutations` (§4, §7.2) | **fatto e in produzione**, collaudato su utente usa-e-getta |
| 4 | Paginazione del pull | **fatto**. `SyncPagination`, 8 test verdi |
| 5+ | Integrazione client, import, UI, sociale | da fare ← ripartire da qui |

## Cosa gira in produzione adesso

- `tmdb_shows`, `tmdb_episodes`, `tvdb_tmdb_map`, `watch_events`, `tv_show_state` — tutte con RLS,
  zero policy di scrittura sul catalogo, `user_status` unica colonna scrivibile dal client su
  `tv_show_state`.
- `recompute_tv_show_state`, `refresh_backlog_since`, `user_today`, `user_counts_specials`,
  `is_special_episode`, `tv_tracking_bucket`, vista `v_tv_tracking`, 2 trigger statement-level.
- `apply_mutations` con 17 rami, inclusi `watch_events` e `tv_show_state`. Il collaudo (utente
  usa-e-getta dentro una transazione fatta fallire apposta, quindi zero residui in produzione) ha
  verificato: 2 eventi atterrano e il trigger scrive `tv_show_state` 2/73/73 con `next=S1E3`; lo
  **stesso batch rigiocato** non duplica e non produce rifiuti (criterio 2 di §13); un client che
  manda `watched_count: 999` si vede tenere i contatori del server e cambiare solo `user_status`
  (§4 `serverWins`); una DELETE fa soft-delete e il ricalcolo riporta `next` a S1E2. Zero righe in
  `sync_rejected_mutations` in tutti e quattro i passaggi.
- Job `pg_cron` `refresh-backlog` alle 05:00 UTC.
- Edge Function `catalog-resolve` versione 3, `verify_jwt` attivo.
- Droppati: `tv_tracking`, `tv_episode_progress`, `v_tv_tracking_buckets`,
  `get_tv_tracking_buckets()` (erano a 0 righe, verificato subito prima).
- Catalogo popolato con una sola serie di prova: Game of Thrones (1399), 373 episodi.

## Cose imparate che risparmiano tempo

- **Il `DA VERIFICARE` di §5 era vero**: il pull faceva `select("*")` senza `range()` *e* senza
  `order()`. Il tetto di questo progetto però non è PostgREST — `pgrst.db_max_rows` non è impostato
  (verificato il 2026-07-31 su `pg_db_role_setting`) — ma lo **`statement_timeout = 8s` del ruolo
  `authenticated`**: 20.000 righe in una richiesta sola non tornavano troncate in silenzio, non
  tornavano affatto. Il troncamento silenzioso resta però a un `ALTER ROLE` di distanza.
- **`order()` non è cosmetico quando si pagina.** Senza `ORDER BY` Postgres può restituire le righe
  in ordine diverso a ogni richiesta, e due finestre sulla stessa tabella riescono a sovrapporsi e a
  saltare righe contemporaneamente. Si ordina per chiave primaria, che è unica dentro l'insieme
  filtrato.
- **Il target `VibeWatchAppTests` non è un gruppo sincronizzato col filesystem, il target app sì.**
  Un file nuovo sotto `VibeWatchApp/` viene compilato da solo; uno nuovo sotto `VibeWatchAppTests/`
  va aggiunto a mano al `project.pbxproj` in quattro punti (`PBXBuildFile`, `PBXFileReference`,
  figli del gruppo, fase `Sources`), altrimenti `xcodebuild test -only-testing:` risponde
  **"Executed 0 tests"** e conclude **TEST SUCCEEDED**. Un test che non esiste non fallisce mai.

- **L'ordine dei file di migration non è l'ordine con cui sono stati applicati.** `movie_reactions`
  e `unified_user_preferences` erano stati aggiunti ad `apply_mutations` per *splice* sul `prosrc`
  reale, ma i due file che riscrivono la funzione intera (`_complete`, `_per_item_isolation`) hanno
  un nome che li mette **dopo**. In produzione l'ordine vero era l'inverso e i due rami c'erano;
  riscrivere la funzione partendo dal file `_per_item_isolation` li avrebbe cancellati in silenzio,
  mandando ogni reaction e ogni preferenza in `table_not_handled` — la stessa perdita di dati contro
  cui la migration si proponeva di proteggere. **Prima di un `create or replace` su una funzione
  vecchia, confrontare con il `prosrc` reale, non con l'ultimo file in cartella.** Il confronto
  costa poco: `md5` del `prosrc` normalizzato (commenti via, spazi collassati) contro lo stesso
  calcolo fatto in locale.
- **Un collaudo in produzione si può fare senza lasciare residui**: tutto dentro un `do $$ ... $$`
  che finisce con `raise exception 'REPORT %', rep`. Il messaggio dell'errore torna indietro come
  output, e il rollback porta via utente di prova e righe. Niente da ricordarsi di cancellare.

- **I revoke sulle funzioni vanno fatti a `PUBLIC`**, non ad `anon`/`authenticated`: Postgres
  concede EXECUTE a PUBLIC di default e i due ruoli lo ereditano. Un revoke mirato non toglie
  niente, e `has_function_privilege` continua a rispondere `true`.
- **Postgres rifiuta una transition table insieme a una lista di colonne**: `after update of
  deleted_at ... referencing old table` non si può scrivere. Il filtro sulla colonna va dentro la
  funzione del trigger.
- **`api_proxy_budget` ha un CHECK che enumera i provider**: ogni nuovo proxy richiede una
  migration, altrimenti `trySpend` fallisce chiuso e la funzione rifiuta tutto.
- **`/find` di TMDB restituisce spesso hit in più bucket per lo stesso id** (Game of Thrones:
  `tv: 1, tv_episode: 1`). Decide solo il bucket richiesto; considerare ambigua ogni collisione
  mandava alla pila manuale la maggior parte di un import.
- **Il fuso**: il job gira in UTC ma il ricalcolo usa `user_today`, quindi il filtro del job ha un
  giorno di margine (`current_date + 1`), o chi vive a UTC+14 vede l'episodio con 24 ore di ritardo.
- **312 utenti, 98 con identità email**: due terzi entrano con Apple o Google. Conta per il blocco
  8 — assegnare uno username agli utenti OAuth è il pezzo centrale, non il login con username.
- **Game of Thrones ha 300 speciali su 373 episodi in TMDB.** È la conferma pratica di §1.3: se
  gli speciali entrassero nel progresso, una serie finita mostrerebbe 73/373.

## Come si collauda

```bash
supabase/tests/run.sh                      # Postgres usa-e-getta, migration x2, 64 asserzioni
python3 test_oracle.py                     # oracolo, 22 test
cd supabase/functions/catalog-resolve && deno test    # logica pura, 24 test
xcodebuild test -project VibeWatchApp.xcodeproj -scheme VibeWatchApp \
  -destination 'id=601C4430-6213-49E3-8A4D-3564B2B57E2A'   # iOS: 3 fallimenti PREESISTENTI
```

I 3 test iOS che falliscono (`ConflictResolverTests` x2, `SyncStateMachineTests.testIdleToIdle`)
fallivano già prima di questo lavoro e sono fuori scope.

## Documenti di riferimento

- `SPEC v3.md` — la spec (gitignored, sta solo sul disco)
- `.planning/spec-v3-oracle.md` — le 31 divergenze dell'oracolo, 4 ancora da risolvere
- `.planning/spec-v3-blocco2-catalogo.md` — catalogo e risoluzione TVDB→TMDB
- `.planning/spec-v3-blocco3-tracking.md` — eventi, stato, trigger, cron
