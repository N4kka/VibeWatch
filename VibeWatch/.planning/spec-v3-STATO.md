# SPEC v3 — stato del lavoro e ripresa

> Aggiornato: 2026-07-31, fine sessione. Branch: `refactoring/spec-v3-prereqs-oracle`.
> Progetto Supabase: `rqhxhkijzhqivljivirq` (VibeWatch, eu-west-1, Postgres 17.6).
> Repo: `/Users/nicola/Documents/StartingVibe/VibeWatch` (git root un livello sopra).

**Il filo conduttore di questa sessione, se ne va letto uno solo.** Ogni problema costato tempo era
un fallimento *silenzioso*, non un errore: un `try?` che ingoiava un 401, un `?? ""` che rendeva
una chiave mancante indistinguibile da una vuota, un `create or replace` che avrebbe cancellato due
rami senza dirlo, un IDOR che rispondeva come se il job fosse tuo. Nessuno di questi si vede
leggendo il codice: si vedono **eseguendolo e provando a romperlo**. Quando un test passa al primo
colpo, vale la pena rompere apposta ciò che dovrebbe coprire e controllare che fallisca — su
`assignRewatchIndex` l'ho fatto e ho scoperto che il test dell'oracolo non copriva il caso che
credevo.

## Da fare per prima cosa

**Blocco 6: resta il collaudo delle fasi 5-6 e la decisione sul budget TMDB.** Le fasi 1-4 sono
fatte, deployate e collaudate end-to-end sull'export vero. Le fasi 5-6 sono scritte e collaudate
in SQL, ma `import-finalize` **non è ancora deployata**.

| Fase | Cosa manca | Note per chi la scrive |
|---|---|---|
| 4. `writing` | **fatta, deployata e collaudata** (`supabase/functions/import-write/`, 11 test Deno + collaudo end-to-end) | Legge da `import_staging` le righe `status='resolved'`. **Il record DEVE contenere `user_id`**, altrimenti `apply_mutations` scrive `user_id_mismatch` in `sync_rejected_mutations` e prosegue in silenzio. `dedup_key` è già nello staging e rende l'operazione idempotente (criterio 2 di §13). **`is_special` va derivato dalla stagione RISOLTA da TMDB** (`resolved->>'season_number'`), non dal record grezzo: dopo il `resolving` la stagione autorevole è quella di TMDB, ed è quella che `recompute_tv_show_state` filtra con `is_special_episode`. Il flag originale di TV Time sta in `tvtime_is_special_raw` e va in `external_ref`. Una riga con `numbering_known = false` rimasta irrisolta **non è scrivibile** (il CHECK `watch_events_shape` vuole stagione ed episodio non nulli): va nel report, mai scritta con un numero inventato. |
| 5. `recomputing` | **scritta** (`import-finalize`), da deployare | **Domanda risolta: non serve per la correttezza, conviene come assicurazione.** Il trigger `watch_events_recompute_insert` è statement-level e ricalcola ogni `(user, show)` distinto di ogni INSERT; `apply_mutations` inserisce un elemento per volta, quindi lo stato è già giusto a fine fase 4. Misurato in produzione (utente usa-e-getta, transazione fatta fallire): **100 insert con trigger = 250 ms**, un ricalcolo singolo = **2,6 ms**, stima sull'export vero **~53 s** di lavoro DB contro ~1 s che costerebbe un giro finale su ~430 serie. Lo spreco è reale ma assoluto piccolo; la fase 5 vale come garanzia che un job interrotto fra due lotti finisca comunque consistente. |
| 6. `done` | **scritta**: `public.import_report(job_id)` + `import-finalize`, 13 asserzioni SQL | **Obbligatorio, non decorativo.** Dice: N episodi/serie/film, intervallo di date, **N non riconosciuti con l'elenco dei titoli**, N voti indecodificabili. I dati ci sono già: `import_jobs.totals` e le righe `status='unresolved'` con la loro `error`. |

Il modello da seguire per le nuove Edge Function è `import-resolve/index.ts`, che è la più recente
e incorpora tutte le lezioni: lettura del job col JWT del chiamante, lavoro limitato per
invocazione, `status='failed'` scritto sul job in caso di eccezione.

## Stato dei blocchi di §12

| # | Blocco | Stato |
|---|---|---|
| 0 | Prerequisiti P1-P5 | **fatto**, in repo. P2/P3 non verificabili senza un build reale |
| 1 | Oracolo + fixture + harness | **fatto**. 31 test Python verdi, baseline 389/41/37, **zero divergenze senza spiegazione** |
| 2 | Catalogo + `catalog-resolve` | **fatto e in produzione**, verificato end-to-end su Game of Thrones |
| 3 | `watch_events` + `tv_show_state` | **fatto e in produzione**. Harness SQL, 64 asserzioni verdi |
| — | `apply_mutations` (§4, §7.2) | **fatto e in produzione**, collaudato su utente usa-e-getta |
| 4 | Paginazione del pull | **fatto e verificato**. `SyncPagination`, 8 test verdi + pull reale sul dispositivo, nessun `Failed to pull` |
| 5 | Integrazione client | **fatto per la lettura**. SQLite + whitelist + pull + conflitti verificati su dati veri; il percorso di scrittura è cablato ma senza chiamanti (arrivano col blocco 7) |
| 6 | Pipeline import + report | **fasi 1-4 in produzione e collaudate end-to-end**; fasi 5-6 scritte e verdi in SQL, `import-finalize` da deployare |
| 7+ | UI, sociale, stats | da fare |

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
- **Import**: tabelle `import_jobs` e `import_staging` (RLS con sole policy di lettura: le fasi le
  muove il server), bucket privato `imports` con policy che confinano ogni utente alla propria
  cartella, Edge Function `import-parse` (fase 2, **versione 3**), `import-resolve` (fase 3) e
  `import-write` (fase 4). Nessun `import_jobs` residuo: lo staging dei collaudi è stato cancellato.
- Droppati: `tv_tracking`, `tv_episode_progress`, `v_tv_tracking_buckets`,
  `get_tv_tracking_buckets()` (erano a 0 righe, verificato subito prima).
- Catalogo: **1.912 episodi e 592 voci di `tvdb_tmdb_map`**, residuo *voluto* del collaudo — è
  §1.5, il primo che importa paga e tutti gli altri trovano la serie già risolta.

## La finestra a 12 mesi, verificata

Collaudo del 2026-07-31 su utente usa-e-getta (transazione fatta fallire, zero residui): 5 eventi
scritti fra il 2015 e il 2026, di cui 3 fuori finestra. Risultato:

- il client ne ritira **2**, i soli dentro i 12 mesi — il filtro funziona sotto RLS, letto col ruolo
  `authenticated`;
- `tv_show_state` conta **5/73/73**: i contatori restano completi anche sugli eventi che il client
  non scaricherà mai. È il punto centrale dell'opzione B — il progresso non si degrada;
- tre pagine da una riga danno `[5][4][vuota]`: righe distinte, nessuna sovrapposizione, e la
  pagina vuota chiude la camminata come `SyncPagination` si aspetta.

## L'import, collaudato sull'export vero

Lo ZIP reale (`gdpr-data.zip`, **non** in repo: è l'archivio GDPR di una persona) è stato caricato
su Storage e fatto passare per le fasi 2 e 3. Numeri, identici a quelli di `build_oracle.py` sullo
stesso archivio:

```
21.344 eventi · 380 voti · 21.724 righe di staging · 21.344 dedup_key distinte
v1 inutilizzabili: 139 · v1 scartati come duplicati: 15.906
6 invocazioni di import-parse, checkpoint 0→4000→…→21724, fase finale `resolving`
```

Quel 15.906 è la conferma pratica di §7.3: il file legacy contiene quasi gli stessi eventi di v2, e
fonderli per `(stagione, episodio)` invece che per `tvdb_episode_id` avrebbe inventato migliaia di
visioni.

**Due difetti trovati eseguendo, non leggendo** — entrambi corretti:

1. **IDOR in `import-parse`**: cercava il job con la chiave di servizio e selezionava `user_id`
   senza confrontarlo mai. Un utente autenticato poteva passare il `job_id` di un altro, far
   rielaborare il suo import, leggerne i totali e marcarglielo come fallito. Riprodotto fra due
   utenti prima di chiuderlo. La correzione non aggiunge un `if` — la lettura passa dal JWT del
   chiamante, quindi decide la policy. **Fare lo stesso in ogni funzione nuova.**
2. **`zip.js` decomprime su web worker e non li chiude**: in una Edge Function sarebbero worker che
   sopravvivono alla risposta. Risolto con `configure({ useWebWorkers: false })` e
   `terminateWorkers()` nel `finally`. L'ha trovato il rilevatore di leak dei test.

## Il collaudo end-to-end delle fasi 2-4 (2026-07-31)

Utente usa-e-getta, ZIP vero caricato su Storage col JWT dell'utente, pipeline intera, **tutti i
dati utente cancellati alla fine** (verificato a zero); il catalogo risolto è rimasto, ed è il
punto di §1.5: 1.912 episodi e 592 voci di mappa che il prossimo import trova già fatte.

**Cosa ha funzionato.** La fase 2 ha prodotto esattamente i numeri di `build_oracle.py` (21.344
eventi, 380 voti, 21.724 righe, 139 v1 inutilizzabili, 15.906 scartati) e le regole nuove sono
atterrate nello staging identiche all'oracolo: **195 numerazioni perse, 613 speciali tutti in
stagione 0, zero eventi con specialità non derivata dalla stagione, 128 flag in disaccordo**.
La fase 4 ha scritto 558 eventi su 14 serie con zero rifiuti. **Criterio 2 di §13 verificato su
dati veri**: rigiocando lo stesso lotto restano 558 eventi e zero rifiuti. **Criterio 1 sul
sottoinsieme**: delle 14 serie, 8 sono state importate per intero e **8 su 8 riproducono il
progresso dell'oracolo**.

**Tre problemi trovati, di cui uno grosso.**

1. **Un import reale richiede ~35 ore.** `catalog-resolve` fa **una chiamata `/find` per
   episodio** e `CALLER_CALLS_PER_HOUR` è 600: 21.189 episodi distinti = 35,3 ore. Il budget
   globale (50.000/giorno) non è il vincolo, lo è il tetto orario per utente. Misurato: 12
   invocazioni hanno risolto 600 episodi e poi il tetto ha chiuso, esattamente come previsto.
   È il momento di acquisizione (§10) e la spec promette "una push a fine import": va deciso se
   alzare il tetto per i job di import, se raggruppare le `/find`, o se cambiare la promessa.
2. **`import-resolve` si impianta a budget esaurito.** Non annota **nessuna** riga finché
   *tutti* gli id del blocco sono in mappa: con 994 mancanti in un blocco e 600/ora, passano due
   ore prima che una sola riga venga annotata, e nel frattempo ogni invocazione torna
   `done: false` senza aver fatto progressi. Andrebbe annotato ciò che è già risolvibile.
3. **`ROWS_PER_INVOCATION = 4000` in `import-resolve` è una costante che mente**, per il tetto
   PostgREST qui sopra. Non è perdita di dati — il ciclo continua — ma la fase costa quattro
   volte le invocazioni previste.

**Un difetto mio, corretto subito:** `totals.written` contava le mutazioni *costruite*, non le
righe nate. Dopo il rigioco dichiarava 1116 episodi importati con 558 in tabella. Ora conta gli
inserimenti veri e tiene `already_present` separato — un report che gonfia i numeri è
esattamente ciò che §7.4 vieta.

## Due cose da sapere prima del blocco 7

- **Chi accoda una mutazione su `watch_events` deve mettere `user_id` nel record.**
  `apply_mutations` confronta `rec->>'user_id'` con `auth.uid()` e, se non combacia o manca,
  scrive `user_id_mismatch` in `sync_rejected_mutations` e va avanti: nessun errore visibile al
  client. `normalizedMutationRecord` riempie `id` ma non `user_id`.
- **Il totale di tempo di visione (§13.7) non può più essere sommato dal client**, perché in cache
  c'è solo un anno di eventi. Deve arrivare dal server come aggregato — coerente con §1.1, e serve
  comunque alle stats del blocco 9.

## Cose imparate che risparmiano tempo

- **Un oracolo che combacia troppo sta misurando la cosa sbagliata.** Le 4 divergenze "da
  risolvere" erano in realtà 2 difetti del parser, presenti sia in `build_oracle.py` sia in
  `parsing.ts`. (a) `is_special` veniva letto dal flag dell'export invece che dalla stagione: TV
  Time lo popola solo sui record recenti, quindi 128 eventi lo hanno in disaccordo con la propria
  stagione, **in entrambe le direzioni**. (b) `episode_number = 0` veniva preso per "episodio
  zero" quando invece significa "TV Time ha perso la numerazione" (`ep_no: 0`, `runtime: 0`,
  `updated_at` 2023): 195 eventi su 12 serie, che venivano fusi su un'unica coppia — Mario perdeva
  16 episodi distinti dentro uno. Il sintomo era **il contrario di un fallimento**: la baseline
  diceva 399/31, e 10 di quelle coincidenze erano false perche' l'oracolo replicava il criterio di
  TV Time invece di quello di §1.3. Game of Thrones e' il caso di controllo: l'oracolo diceva 74,
  `recompute_tv_show_state` dice 73. Baseline corretta: **389/41, zero divergenze inspiegate**.
- **Una causa di divergenza si assegna sommando termini misurati, non scegliendo una categoria.**
  Ogni divergenza porta ora un campo `explained_by` con la combinazione che chiude lo scarto: e' la
  prova aritmetica, e permette di rivalutarla senza rifare l'analisi. I termini sugli speciali sono
  **due** (per stagione e per flag) perche' `ep_watch_count` e' un contatore incrementato per un
  decennio da versioni diverse dell'app e le due ere hanno lasciato entrambe il segno: Spartacus e
  Doctor Who contano per stagione, Naruto e X Factor per flag.
- **Un'ipotesi che spiega la serie che stai guardando va provata su tutte le altre.** Per
  Billionaires' Bunker (2 vs 8) l'ipotesi ovvia era "TV Time non conta i `fill-previous`": provata
  sull'export intero, **131 serie su 132 li contano**. Ristretta alla forma esatta del caso (il
  backfill precede la nascita della riga contatore), 14 su 15 li contano. E' un'eccezione — un
  contatore nato a 1 invece che a 7 — non una regola, e il test lo verifica.
- **Questa clone non aveva i segreti.** `VibeWatchApp/Config/Secrets.xcconfig` è gitignored ed era
  nato come placeholder vuoto "perché il progetto compilasse e i test girassero": 6 chiavi su 8
  senza valore. I valori veri stanno nella clone dell'audit,
  `/Users/nicola/Documents/VibeWatch/VibeWatch/`. Conseguenza a runtime: TMDB 401, Scopri bianca,
  RevenueCat "Invalid API Key" — e **build e test tutti verdi**, perché nessuno dei due percorsi
  tocca la rete reale. Escluse di proposito `RAPIDAPI_KEY` e `YOUTUBE_API_KEY`, che
  `audit/04-dependencies.md` aveva rimosso.
- **Negli URL dentro xcconfig le barre si scrivono `https:\/\/host`.** Scrivere `https:$()//host`
  **tronca il valore a `https:`**: xcconfig toglie i commenti *prima* di espandere le variabili,
  quindi vede il `//` letterale. Era il caso di `SUPABASE_URL`, cioè ogni chiamata a Supabase
  partiva verso un URL spazzatura. `Config.string(for:)` ripara `https:/` → `https://`, ma su
  `https:` non c'è niente da riparare. **Verificare l'`Info.plist` del bundle costruito**, non il
  file sorgente: `PlistBuddy -c "Print :SUPABASE_URL" .../VibeWatchApp.app/Info.plist`.
- **Lo schema gira in Release e `Logger` è interamente dentro `#if DEBUG`.** In Release l'app non
  stampa una riga: nessun `[SyncEngine]`, nessun `[DiscoveryViewModel]`. Prima di chiedere un log a
  qualcuno, controllare che quel log possa esistere.
- **Tre fallimenti silenziosi in un giorno, stesso schema**: `try?` nel pull (introdotto e
  corretto), `try?` in `LiveDiscoveryRepository` (preesistente, ora logga), `?? ""` in
  `Config.string(for:)` (ancora lì). Il costo non è il bug, è la diagnosi: un segreto mancante si è
  presentato come una schermata bianca e ha portato a sospettare prima il blocco 4, poi una VPN.

- **Il `DA VERIFICARE` di §5 era vero**: il pull faceva `select("*")` senza `range()` *e* senza
  `order()`. Il tetto di questo progetto però non è PostgREST — `pgrst.db_max_rows` non è impostato
  (verificato il 2026-07-31 su `pg_db_role_setting`) — ma lo **`statement_timeout = 8s` del ruolo
  `authenticated`**: 20.000 righe in una richiesta sola non tornavano troncate in silenzio, non
  tornavano affatto. Il troncamento silenzioso resta però a un `ALTER ROLE` di distanza.
  > **CORREZIONE del 2026-07-31, misurata:** il tetto PostgREST **c'è ed è 1000 righe.**
  > `pgrst.db_max_rows` è davvero nullo sul ruolo — guardare lì è ciò che aveva portato alla
  > conclusione sbagliata — ma il limite sta nella configurazione PostgREST del progetto, dove
  > `pg_db_role_setting` non lo vede. Scoperto perché `import-resolve` chiede `.limit(4000)` e ne
  > riceve 1000: sull'export vero le prime 4.000 righe contengono 3.994 episodi distinti, e la
  > funzione ne vedeva 994. **Ogni `.limit()` sopra 1000 in questo progetto è già troncato oggi**,
  > in silenzio: `SyncPagination` è salvo solo perché pagina a 1000 esatti.
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

- **I revoke sulle funzioni vanno fatti a `PUBLIC` *e* ad `anon`/`authenticated`.** La prima
  metà era già scritta qui e da sola porta fuori strada: Postgres concede EXECUTE a PUBLIC di
  default, ma su Supabase c'è **anche** un `ALTER DEFAULT PRIVILEGES` che lo concede in modo
  **esplicito** ai due ruoli client. Revocare solo a PUBLIC non toglie i grant espliciti e
  `has_function_privilege` continua a rispondere `true` — verificato il 2026-07-31 su
  `import_touched_shows`, che è `security definer` e prende un `job_id` arbitrario: sarebbe
  bastato per farsi dire quali serie ha importato un altro utente. **Il controllo che vale è
  `proacl`**, non il revoke che si è scritto: se ci si legge `anon=X/postgres`, il revoke non ha
  fatto niente.
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
python3 test_oracle.py                     # oracolo, 31 test
cd supabase/functions/catalog-resolve && deno test            # logica pura, 24 test
cd supabase/functions/import-parse   && deno test --allow-read  # parser, 14 test

# Il 15° test del parser (l'apertura dell'archivio) gira solo se gli si dà l'export vero,
# che non è in repo — senza `--allow-env` la suite fallisce sul permesso, non sul codice:
TVTIME_ZIP=~/Downloads/gdpr-data.zip deno test --allow-read --allow-env

# iOS: se la config è incompleta, l'app si ferma all'avvio in DEBUG con l'elenco
# delle chiavi mancanti (Config.validateAtLaunch). Non è un bug: sono i segreti.
xcodebuild test -project VibeWatchApp.xcodeproj -scheme VibeWatchApp \
  -destination 'id=601C4430-6213-49E3-8A4D-3564B2B57E2A'   # iOS: 3 fallimenti PREESISTENTI

# Deploy di una Edge Function: dalla radice del repo, non da supabase/
supabase functions deploy import-parse --project-ref rqhxhkijzhqivljivirq
```

I 3 test iOS che falliscono (`ConflictResolverTests` x2, `SyncStateMachineTests.testIdleToIdle`)
fallivano già prima di questo lavoro e sono fuori scope.

### Collaudare in produzione senza lasciare residui

Due modi, entrambi già usati:

- **Solo SQL** — tutto dentro un `do $$ … $$` che finisce con `raise exception 'REPORT %', rep`: il
  messaggio torna indietro come output e il rollback porta via utente di prova e righe.
- **Con HTTP** (serve un JWT vero, quindi niente rollback) — creare l'utente con
  `crypt('password', gen_salt('bf'))` e **valorizzare a `''` le colonne token** di `auth.users`
  (`confirmation_token`, `recovery_token`, `email_change*`, `phone_change*`,
  `reauthentication_token`): a `NULL` GoTrue risponde *"Database error querying schema"* e il login
  fallisce. Alla fine cancellare **prima** la riga in `public.profiles` e poi l'utente: la FK
  `profiles_id_fkey` non ha `ON DELETE CASCADE`.

## Documenti di riferimento

- `SPEC v3.md` — la spec (gitignored, sta solo sul disco)
- `.planning/spec-v3-oracle.md` — le 31 divergenze dell'oracolo, 4 ancora da risolvere
- `.planning/spec-v3-blocco2-catalogo.md` — catalogo e risoluzione TVDB→TMDB
- `.planning/spec-v3-blocco3-tracking.md` — eventi, stato, trigger, cron
- `audit/HANDOFF.md` — l'audit del 2026-07-23. **Attenzione: parla di un'altra clone**
  (`/Users/nicola/Documents/VibeWatch/VibeWatch/`), ed è da lì che vengono i segreti. Il §3b elenca
  bug preesistenti mai chiusi; quello sul `readerDb` readonly è già risolto (verificato: `upsert`
  passa da `executeWrite`), gli altri no.
- `build_oracle.py` — **la specifica eseguibile del parsing**. Le regole dell'import stanno lì
  prima che nella spec: se una regola sembra arbitraria, è perché un export reale l'ha resa tale.

## Cose che restano aperte, in ordine di costo

1. **`Config.string(for:)` restituisce `""` in silenzio** per una chiave mancante. Ora c'è
   `validateAtLaunch` che elenca le chiavi vuote o malformate, ma **in Release non lascia traccia**
   perché `Logger` è tutto dentro `#if DEBUG`. Il posto dove agganciare Crashlytics è segnato nel
   punto di chiamata.
2. **`import-parse` risponde 500 senza JWT valido** (`Expected 3 parts in JWT`). Fallisce chiuso,
   quindi non è un buco, ma un 401 sarebbe più onesto e non farebbe scattare i retry del client.
3. **Rifiuti veri in `sync_rejected_mutations`**: `lists` con `constraint_23505` su
   `idx_lists_one_active_default_per_user_type`, 6 occorrenze fra il 27 e il 29 luglio. Il client
   prova a ricreare una lista di default che esiste già.
4. **`delete-user` cancella 5 tabelle su ~30** (audit §3b) e `profiles.id` non ha
   `ON DELETE CASCADE`: cancellare un utente fallisce se non si toglie prima il profilo. È materia
   GDPR.
