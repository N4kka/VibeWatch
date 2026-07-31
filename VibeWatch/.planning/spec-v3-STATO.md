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

**Misurare §13.6 sul dispositivo, in Release.** È l'ultimo pezzo aperto del blocco 7, ed è l'unico
che non si può fare da qui: serve il telefono. La sonda è pronta e corretta (vedi sotto — aveva un
difetto che l'avrebbe resa inutile anche con dati veri).

Come si legge, in ordine di comodità:

1. **Console.app** col telefono collegato, filtro su sottosistema `com.vibewatch.app` e categoria
   `TrackingPerf`. Passa da `os.Logger` e non dal `Logger` del progetto proprio per questo: quello
   è tutto dentro `#if DEBUG` e in Release non stampa una riga.
2. **Instruments**, template *Points of Interest*, intervallo `TrackingFirstFrame`.
3. Un test con `XCTOSSignpostMetric(subsystem: "com.vibewatch.app", category: "Tracking",
   name: "TrackingFirstFrame")`, che dà una distribuzione invece di un aneddoto.

Cosa aspettarsi in console:

```
§13.6 dati pronti in 12.3 ms (24 righe)
§13.6 OK: totale 148.2 ms (dati + disegno 135.9 ms) — budget 300 ms
```

**Se compare `misura scartata`**, il capolinea è scattato prima dei dati e non c'è nessun numero da
credere: è la rete di sicurezza, non un guasto della schermata.

**La misura in DEBUG non vale**: Swift non ottimizzato dà un numero pessimista e inutile.

### La sonda misurava la cosa sbagliata — corretto

Il `61,9 ms` registrato in precedenza era stato attribuito all'account senza storico. Non era
quello: era **strutturale**, e avrebbe dato un numero falso anche con 24 serie in lista.

La sequenza reale: `begin()`, `isLoading = true`, SwiftUI ridisegna, la `List` compare **vuota**
— i dati sono ancora dentro l'`await` di `fetchSections()` — la riga sentinella appare e chiudeva
il cronometro. Si misurava il tempo di disegnare una lista vuota, cioè il contrario di ciò che
§13.6 chiede.

Due correzioni, perché una sola non basta: la sentinella ora esiste **solo se ci sono sezioni**
(quindi il capolinea è il primo fotogramma con contenuto), e `firstFrameRendered()` scarta la
misura se `dataReady` non è mai arrivato, lo dichiara nel log e restituisce `nil` invece di un
numero. Cinque test in `TrackingSyncTests` fissano l'invariante, provati togliendo la guardia.

### La migrazione è girata, sul dispositivo dell'autore

```
[LegacyMigration] 4 episodi, 22 serie viste per intero, 24 serie da riscaldare — tentativo 1
[LegacyMigration] 4 episodi + 967 da espansione, completata=true
```

**967 episodi da 22 serie**, primo tentativo, nessuna serie rimasta senza catalogo. Il rapporto
4:967 è la conferma pratica del punto centrale del progetto: quasi tutto lo storico di questo
utente stava in `seenShowIds` e nella lista `seen`, cioè nella forma che **non dice quali
episodi**. La strada "scrivo solo `user_status`" avrebbe migrato 4 episodi su 971 e messo 22 serie
finite fra le "Da iniziare".

`completata=false` con un elenco di serie senza catalogo resta un esito **previsto**, non un
guasto: il riscaldamento può essere tagliato dal budget o dalla deadline di `catalog-resolve`, e il
prossimo avvio riprova (3 tentativi, poi si chiude).

### Il difetto trovato subito dopo: "visto" non faceva niente

Premere il segno di spunta scriveva l'evento in produzione e **non cambiava niente sullo schermo**.
Non era il tap: era che `TrackingActions` accodava la mutazione e la spingeva, ma il progresso lo
ricalcola il server (§1.1) e la schermata legge lo specchio locale `tv_tracking`, **che solo un
pull aggiorna**. `queueOperation` fa `pushPendingChanges()` e basta. Quindi `viewModel.load()`
rileggeva righe identiche.

È la forma di guasto peggiore fra quelle di questa sessione: non un errore, non un log, e l'invito
implicito a premere di nuovo — cioè a marcare due episodi.

Tre correzioni:

1. **`SyncEngine.pullTrackingState()`**, mirato su `tv_show_state` + le due viste. Un
   `pullFromRemote()` qui sarebbe 19 tabelle per un tocco. Lo chiamano `markNextWatched` e
   `setStatus` dopo aver accodato.
2. **`v_tv_tracking` e `v_tv_timeline` erano nel `default` di `TableConflictMapping`**, cioè
   `lastWriteWins`, che confronta per `updated_at` — e `v_tv_timeline` un `updated_at` non ce l'ha.
   Sono specchi che nessuno scrive in locale: ora `serverWins`, come `tv_show_state`.
3. **Stato "in volo" sulla card.** Fra il tap e la card aggiornata c'è un giro di rete: il pulsante
   mostra un indicatore e si disabilita, e un'azione per volta.

**Nota su cosa è disabilitato di proposito:** su una serie in pari il segno di spunta è pieno e
verde e **non fa niente**, perché non c'è un prossimo episodio da marcare. Dopo la migrazione sono
22 serie su 24, quindi è la condizione più comune. Se dovesse sembrare un guasto, è lì che va
guardata la UI — non il percorso di scrittura.

### Il collaudo in produzione, 2026-07-31 — fatto

**Prima parte, in SQL, dentro un `do $$ … $$` chiuso da `raise exception 'REPORT %'`**: catalogo
finto, utente usa-e-getta, tutto portato via dal rollback (residui verificati a zero). Esito: 5
eventi sui 7 episodi (fuori il futuro e lo speciale), rigioco **0**, `watched_at_precision`
`inferred` su tutte le righe, runtime 2520 s = 42 minuti dal catalogo, `tv_show_state` 5/5/6 con
`backlog_since` nullo e **`bucket = up_to_date`**, `show_name` presente nella vista, e `anon`
respinto con `42501`.

**Seconda parte, via HTTP** (serve un JWT vero, quindi niente rollback: utente cancellato a mano
alla fine, residui verificati a zero). Su **Breaking Bad**, che prima del collaudo non era in
catalogo:

| Passo | Esito |
|---|---|
| `catalog-resolve` con `{"show_ids":[1399]}` — serie già fresca | 0 chiamate a TMDB, 0 popolate: il TTL regge |
| `catalog-resolve` con `{"show_ids":[1396]}` — serie assente | **71 episodi scritti** |
| `{}` e `{"show_ids":[0]}` | 400 con messaggio, non 500 |
| `entities` da solo, e `entities` + `show_ids` insieme | invariati: la strada TVDB dell'import non si è mossa |
| `apply_mutations` con 2 eventi legacy | 2 righe, zero rifiuti |
| espansione sopra quei 2 eventi | **60** nuove righe, non 62 |
| rigioco dell'espansione | 0 |
| `v_tv_tracking` letta col JWT dell'utente | `Breaking Bad`, `up_to_date`, **62/62/62** |

**Quel 60 è la cosa da non perdere di vista.** Le due sorgenti — episodi singoli dal client ed
espansione dal catalogo — hanno scritto 62 righe in totale, non 64: convergono sulla stessa
`dedup_key`. È la verifica pratica che la sovrapposizione voluta nel piano non costa niente.

Il catalogo di Breaking Bad **è rimasto**, di proposito: è §1.5, è condiviso, e il prossimo utente
che ce l'ha in lista lo trova già pronto.

### Com'è fatta la migrazione

Il difetto era visibile solo eseguendo: pull a posto, 19 tabelle su 19, e schermata vuota, perché
per quell'utente il server non aveva niente. `Loaded 6 lists with 429 items from SQLite` — i dati
c'erano, nel vecchio sistema.

| | |
|---|---|
| **Sorgente** | `EpisodeSeenManager.seenKeys` (`"{showId}_{season}_{episode}"`), `seenShowIds`, e le serie nella lista `seen` — le ultime due **unite**, non scelte: `markShowSeen` scrive in UserDefaults, e un'installazione nuova ha la lista ma non il flag |
| **Destinazione** | un `watch_events` per episodio, via `apply_mutations` in lotti da 200 |
| **`watched_at_precision`** | **`inferred`** sempre. C'è un test che rompe se diventa `exact` |
| **`watched_at`** | la **data di aggiunta alla lista** quando c'è (`MIN(list_items.added_at)`), `now()` altrimenti. Non è estetica: con `now()` su tutto, `backlog_since = greatest(next.air_date, last_watched_at)` metterebbe ogni serie arretrata in cima nello stesso istante e "Non visti da tempo" resterebbe vuota per sempre |
| **`dedup_key`** | `legacy:{show}:{season}:{episode}`, identica nelle due strade |
| **`user_id`** | nel record, sempre. `LegacyTrackingPlan.record` è l'unico posto che lo scrive |
| **`is_special`** | dalla stagione, mai da un flag (§1.3) |
| **Una tantum** | `legacy_tracking_migration_version` in `app_metadata`, più un contatore di tentativi con tetto a 3 |

**`seenShowIds` non si risolve lato client, e la strada "onesta" del piano precedente era
sbagliata.** Scrivere il solo `user_status` lascia `watched_count = 0`, e
`tv_tracking_bucket(...)` con `watched_count = 0` risponde **`not_started`**: una serie finita
finirebbe fra le "Da iniziare". Quindi l'espansione si fa dove c'è il catalogo, cioè in Postgres:
`expand_seen_shows_to_watch_events(p_shows jsonb)` scrive un evento per ogni episodio **già
uscito** e non speciale che `tmdb_episodes` conosce, e restituisce le serie che il catalogo non
conosce ancora perché il chiamante riprovi. Verificato: la serie finisce in `up_to_date`.

**Gli episodi singoli di una serie vista per intero restano nel piano**, anche se l'espansione li
riscriverebbe: l'espansione conosce solo ciò che sta nel catalogo, e l'oracolo documenta 41 serie
su 430 in cui la numerazione dell'utente e quella di TMDB non coincidono. La `dedup_key` fa sì che
la sovrapposizione non costi niente.

**Serviva anche un modo di popolare il catalogo per `tmdb_show_id`,** e non esisteva: tutto
`catalog-resolve` era costruito attorno agli id TVDB dell'export. Chi usa VibeWatch da prima non ha
mai visto un id TVDB. Senza, la migrazione avrebbe prodotto card senza nome, senza poster e senza
prossimo episodio — la vista è `LEFT JOIN`, quindi le serie compaiono comunque, vuote. Ora
`catalog-resolve` accetta anche `{"show_ids": [...]}`, fino a 50, e il client lo chiama prima di
scrivere.

**Perché non passa dall'outbox.** `SyncEngine.queueOperation` fa **una chiamata HTTP per
operazione** e ne processa 50 per sync: qualche centinaio di episodi vorrebbe dire altrettanti
round-trip spalmati su decine di avvii. `apply_mutations` accetta un lotto — è così che lo usa
l'import — e la durabilità che l'outbox darebbe la dà la `dedup_key`. Per la stessa ragione il
ripiego per riga di `applyMutations` è **spento** su questo percorso (`allowClientSideFallback:
false`): risolve i conflitti su `id`, non su `dedup_key`, quindi su un rigioco andrebbe a sbattere
sull'indice unico una riga alla volta.

**Cosa succede se qualcosa fallisce:** non si segna niente come fatto. Il prossimo avvio rigioca, e
la `dedup_key` impedisce i duplicati. Dopo 3 tentativi si chiude comunque, perché una serie che
TMDB non conosce più non si risolverà mai e un ciclo a ogni avvio è la forma di guasto che nessuno
nota.

### Il resto del blocco 7

- **§13.6 non è ancora verificato**, ed è l'unica cosa rimasta del blocco 7: serve il telefono.
  Vedi in cima per come si legge e perché il `61,9 ms` di prima non valeva.
- ~~**18 lingue**~~ — **fatto.** Le 20 lingue hanno le stesse 597 chiavi, zero duplicate, zero
  valori vuoti, segnaposto identici all'inglese, e `LocalizationCoverageTests` (6 test) impedisce
  che il disallineamento torni. Vedi *Le traduzioni* più sotto: l'allineamento ha scoperto altri
  tre difetti, di cui uno grosso.

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
| 7 | UI Tracking | **schermata, tab bar e migrazione dello storico in produzione e collaudate.** La migrazione è girata sul dispositivo dell'autore: 971 episodi, primo tentativo. Resta la misura di §13.6; le 20 lingue sono allineate |
| 8+ | Sociale, stats | da fare |

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
- Edge Function `catalog-resolve`, `verify_jwt` attivo. Job `pg_cron` `catalog-prewarm` alle 03:30 UTC.
  Dal 2026-07-31 accetta anche `{"show_ids": [...]}` (max 50): riscalda il catalogo per serie già
  identificate su TMDB, senza passare da `/find`. È la strada del client, che id TVDB non ne ha mai
  visti.
- `expand_seen_shows_to_watch_events(jsonb)`, `security definer`, `proacl` verificato:
  `postgres=X, service_role=X, authenticated=X` — **niente `anon`**.
- **Import**: tabelle `import_jobs` e `import_staging` (RLS con sole policy di lettura: le fasi le
  muove il server), bucket privato `imports` con policy che confinano ogni utente alla propria
  cartella, Edge Function `import-parse` (fase 2, **versione 3**), `import-resolve` (fase 3) e
  `import-write` (fase 4). Nessun `import_jobs` residuo: lo staging dei collaudi è stato cancellato.
- Droppati: `tv_tracking`, `tv_episode_progress`, `v_tv_tracking_buckets`,
  `get_tv_tracking_buckets()` (erano a 0 righe, verificato subito prima).
- Catalogo: **46 serie e 4.155 episodi** al 2026-07-31 (erano 1.912 episodi dopo il collaudo
  dell'import; il resto lo ha aggiunto `catalog-prewarm` di notte, che è il suo mestiere). Residuo
  *voluto*: è §1.5, il primo che importa paga e tutti gli altri trovano la serie già risolta.

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

1. ~~Un import reale richiede ~35 ore~~ — **risolto**, vedi la sezione qui sotto.
2. ~~`import-resolve` si impianta a budget esaurito~~ — **risolto**: quando non può più chiedere,
   annota comunque le righe già risolvibili invece di girare a vuoto.
3. ~~`ROWS_PER_INVOCATION = 4000` è una costante che mente~~ — **risolto**: portata a 1000, che è
   quanto PostgREST restituisce davvero, con il perché scritto accanto.

**Un difetto mio, corretto subito:** `totals.written` contava le mutazioni *costruite*, non le
righe nate. Dopo il rigioco dichiarava 1116 episodi importati con 558 in tabella. Ora conta gli
inserimenti veri e tiene `already_present` separato — un report che gonfia i numeri è
esattamente ciò che §7.4 vieta.


## Le 35 ore dell'import, e come sono diventate minuti

Il problema non era uno ma due, indipendenti, e **nessuno dei due era TMDB**: misurato, TMDB non
restituisce header di rate limit e accetta 30 chiamate in parallelo senza un solo 429.

**Tutti i numeri qui sotto sono cronometrati sull'export vero, non stimati** — e servivano,
perché ogni stima fatta in questa sessione è stata smentita dalla misura almeno una volta.

| Collo di bottiglia | Prima | Dopo |
|---|---|---|
| `CALLER_CALLS_PER_HOUR = 600` — un tetto nostro | 35 ore | tetto da import dedicato |
| ciclo `/find` **sequenziale** (258 ms l'una) | ~13 s per 50 episodi | **3-5 s** |
| annotazione dello staging, una UPDATE per riga | **47 s** per 1000 righe | **1,0 s** |

**Un import completo: da ~35 ore a ~31 minuti.** Misurato su un blocco reale da 1000 righe:
85,6 s (20 chiamate di risoluzione + 1 di annotazione) × 22 blocchi.

Il terzo collo di bottiglia è comparso solo dopo aver sistemato il secondo: parallelizzate le
`/find`, il tempo si era spostato tutto sull'annotazione, che costava più di tutte le chiamate a
TMDB dello stesso blocco messe insieme. **Il posto dove si perde tempo si sposta appena si sistema
il precedente**, e l'unico modo di saperlo è cronometrare.

**Dove sta il tempo adesso, se qualcuno volesse spingere oltre.** I 4 s per 50 episodi non sono
TMDB: con 10 chiamate in parallelo a 258 ms il pavimento sarebbe ~1,3 s. La differenza è il budget,
che fa **due RPC a Postgres prima di ogni chiamata** (`trySpend` per lo scope del chiamante e per
quello globale) — 100 round-trip al database per invocazione. Si risolverebbe prenotando N unità in
una volta e restituendo quelle non spese. Non è stato fatto: 31 minuti in background con una push
alla fine sono già ciò che §7.2 promette, e il resto è rendimento decrescente.

Quattro interventi, tutti in repo:

1. **`FIND_CONCURRENCY = 10` in `catalog-resolve`.** Il ciclo era `for … await`, quindi 50 entità
   per richiesta erano ~13 s — quasi tutta la deadline da 20 s — per una funzione che in locale non
   fa nulla. È il fattore 10, e non tocca nessuna policy. Deliberatamente modesto: la ragione per
   stare bassi non è il limite di TMDB ma che una chiave condivisa bannata perché sembra uno
   scraper costerebbe molto più dei minuti risparmiati.
2. **Uno scope di budget per l'import.** `CALLER_CALLS_PER_HOUR` resta 600 per l'uso normale;
   `IMPORT_CALLS_PER_HOUR = 30.000` si sblocca **solo presentando un `import_jobs` proprio e in
   fase `resolving`**. Il permesso non è un flag nella richiesta: è l'esistenza di un import vero,
   che nessuno può fabbricare perché su `import_jobs` non c'è policy di scrittura. Gli scope sono
   separati (`user:` / `import:` / `prewarm`) apposta: con un contatore solo, l'import affamerebbe
   l'app proprio mentre l'utente guarda la barra.
3. **`GLOBAL_CALLS_PER_DAY` da 50.000 a 500.000.** A 50.000 l'intera base utenti poteva fare 2,3
   import al giorno — il vincolo vero per una funzione di acquisizione (§10). 500.000 sono ~23
   primi import al giorno e, mediati sulle 24 ore, 5,8 richieste al secondo verso TMDB.
4. **`catalog-prewarm` + cron alle 03:30 UTC.** Prende la coda che gli import hanno lasciato
   indietro e la risolve di notte, con un tetto (`PREWARM_CALLS_PER_HOUR = 10.000`) **sotto**
   quello da import: se il budget globale è conteso deve perdere il lavoro che nessuno sta
   aspettando. È il fix di prodotto vero — la mappa è globale (§1.5), quindi il secondo utente che
   importa una serie popolare non paga niente.

**Cosa NON è stato fatto, di proposito:** agganciare gli episodi per `(stagione, episodio)` invece
che per `tvdb_episode_id`. Risparmierebbe circa il 57% delle chiamate ed è l'unica scorciatoia che
§6 vieta esplicitamente — Digimon ha 253 id distinti su 107 coppie, quindi il match per numero
assegnerebbe l'episodio sbagliato **in silenzio**.

## Il blocco 7, cosa c'e' e cosa manca

> **Provato sul dispositivo il 2026-07-31.** Compila e gira. Tre difetti trovati usandolo, tutti
> corretti tranne il primo, che è aperto e sta in cima a questo documento:
> 1. schermata vuota per un utente esistente → **manca la migrazione**;
> 2. il FAB derivava in diagonale — era l'animazione `repeatForever` che ci avevo messo io: dentro
>    lo stack della tab bar il layout la raccoglie e il pulsante si sposta. Tolta;
> 3. il pannello AI era un `fullScreenCover` senza pulsante di chiusura, cioè una stanza senza
>    porta. Ora è un `sheet` (swipe verso il basso) con anche un pulsante esplicito.


**Fatto.** `v_tv_tracking` e `v_tv_timeline` (catalogo incluso) -> pull -> tabelle SQLite
`tv_tracking` e `tv_timeline` (migration 9) -> `LocalTrackingRepository`, che restituisce sezioni
gia' ordinate e in bucket. `TVTrackingCard` non calcola piu' niente: le sessanta righe di computed
properties e la chiamata TMDB per card sono **eliminate**, non spostate (§1.1). La barra e'
`Discovery · Clips · Tracking · Liste` con l'AI su un pulsante flottante persistente, e il
Tracking non e' piu' una sezione dentro Liste.

**Misurato, ma solo in parte.** La query da 430 serie — il caso peggiore reale — costa **0,66 ms**
di mediana su un SQLite seminato con dati realistici, contro i 300 ms di budget di §13.6. È il
pezzo dominante ma **non e' tutto**: manca il rendering SwiftUI e il tempo di apertura della tab,
che si misurano solo sul dispositivo con un utente vero. **Il requisito di §13.6 non e' ancora
verificato**, e in questa sessione ogni numero stimato invece che misurato e' stato smentito
almeno una volta.

## Le traduzioni, e i tre difetti che l'allineamento ha scoperto

Le 20 lingue hanno ora le **stesse 597 chiavi**: `en` e `it` erano già identiche (595 chiavi), le
altre 18 erano indietro di 24 — tutta la schermata Tracking. Aggiunte e tradotte, non copiate
dall'inglese. `LocalizationCoverageTests` blocca la deriva: stesse chiavi, nessun duplicato,
nessun valore vuoto, segnaposto identici a `en`, ogni `"chiave".localized` del codice esiste in
`en`, e nessun file è la copia di un altro. Tutti e sei provati rompendo apposta il caso che
coprono.

**1. `platforms.title` era definita due volte in 11 lingue**, con valori diversi ("Platforms" e
"Streaming Platforms"). Il caricatore di `.strings` non protesta: tiene l'ultima, in silenzio.
Tolta la prima, così ciò che si vede oggi non cambia.

**2. Il portoghese mostrava un `ai.placeholder` troncato a metà frase.** Stessa causa, effetto
opposto: la seconda definizione vinceva ed era rotta — `"Por exemplo, \"Ficção científica com uma
reviravolta no enredo` — virgoletta aperta e mai chiusa. Tolta quella, torna visibile la prima,
corretta.

**3. Due chiavi che il codice chiama non esistevano in nessuna lingua**: `clips.noListsYet` e
`auth.error.invalidLink`. `.localized` restituisce la chiave quando la traduzione manca, quindi
sullo schermo compariva letteralmente `auth.error.invalidLink`. Scritte in tutte e 20.

### `nl.lproj` conteneva polacco — risolto

**Il difetto peggiore trovato in questo giro, ed era preesistente.** `nl.lproj` era una copia di
`pl.lproj`: differivano per **14 stringhe su 571**. Un utente olandese apriva l'app e leggeva
`"Odkrywaj"`, `"Listy"`, `"Anuluj"`. Verificato che era l'unico caso: le altre 18 lingue sono
coerenti con sé stesse (controllate su `tab.discovery`, `tab.lists`, `common.cancel`,
`common.save`, `lists.watchlist`).

**Tutte e 571 tradotte in olandese.** Struttura, commenti e ordine del file restano quelli di
prima: si sono sostituiti i valori, non le righe, così il confronto con gli altri `.lproj` resta
leggibile. Le 15 stringhe che dopo la traduzione risultano ancora identiche al polacco sono
prestiti e simboli che nelle due lingue coincidono davvero (`AI`, `TV`, `OK`, `PRO`, `FAQ`,
`Min`, `Max`, `Status`, `JustWatch`, `{count}/{limit}`, `< 90 min`…).

**Perché nessun controllo se ne era accorto, e cosa c'è ora.** Il file esisteva, aveva tutte le
chiavi giuste e passava ogni verifica di completezza: la sola cosa che lo distingueva da una
traduzione vera era il **contenuto**. `testNessunaLinguaEUnaCopiaDiUnAltra` confronta i valori a
coppie e fallisce sopra l'85% di uguaglianza — `nl`/`pl` stava al 97%, la coppia più simile fra
lingue diverse sta al **24%**. L'unica eccezione dichiarata è `nb`/`no`, che sono la stessa lingua
con due codici e si somigliano al 73% per costruzione. Provato rimettendo la copia: fallisce.

## Due cose da sapere prima del blocco 7

- **Chi accoda una mutazione su `watch_events` deve mettere `user_id` nel record.**
  `apply_mutations` confronta `rec->>'user_id'` con `auth.uid()` e, se non combacia o manca,
  scrive `user_id_mismatch` in `sync_rejected_mutations` e va avanti: nessun errore visibile al
  client. `normalizedMutationRecord` riempie `id` ma non `user_id`.
- **Il totale di tempo di visione (§13.7) non può più essere sommato dal client**, perché in cache
  c'è solo un anno di eventi. Deve arrivare dal server come aggregato — coerente con §1.1, e serve
  comunque alle stats del blocco 9.
- **`applyMutations` ha un ripiego che risolve i conflitti sulla chiave sbagliata.** Se l'RPC
  risponde 404 *oppure* il corpo dell'errore contiene la stringa `apply_mutations`, il client
  ripiega su una upsert REST per riga con `on_conflict=id`. Per una tabella con una chiave di
  idempotenza diversa da `id` — `watch_events` e la sua `dedup_key` — quel ripiego non deduplica.
  Ora è disattivabile (`allowClientSideFallback: false`) e la migrazione lo disattiva; **ogni
  percorso di scrittura in blocco che nasce da qui deve fare lo stesso.**

## Cose imparate che risparmiano tempo

- **"Non inventare nulla" e "non mentire" non sono la stessa regola, e la prima da sola sbaglia.**
  Per le serie marcate viste per intero, la strada che sembrava più onesta era scrivere il solo
  `user_status` e lasciare i contatori al ricalcolo: non inventa episodi. Ma
  `tv_tracking_bucket(...)` con `watched_count = 0` risponde `not_started`, quindi una serie finita
  sarebbe finita fra le "Da iniziare" — un'affermazione falsa prodotta dal rifiuto di affermare
  qualcosa. La scelta giusta era spostare il lavoro dove c'è il dato (il catalogo, cioè Postgres) e
  dichiarare esplicitamente ciò che resta ignoto (`shows_without_catalog` torna al chiamante).
- **`security invoker` non è sempre la scelta più stretta.** Il primo tentativo di
  `expand_seen_shows_to_watch_events` era invoker, per farsi garantire l'isolamento dalla RLS invece
  che da un `where` scritto a mano. Non funziona: la funzione legge `user_counts_specials`, che al
  client **non è chiamabile apposta** — è una delle cose che il test di §1.1 verifica. Definer,
  allora, ma il punto che conta non è l'etichetta: è che **non esiste un parametro con l'identità**.
  L'IDOR di `import-parse` aveva la forma opposta, un id preso dalla richiesta e mai confrontato.
- **Server-authoritative vuol dire che dopo una scrittura bisogna ricordarsi di rileggere.** §1.1
  toglie il calcolo dal client, e questa è la metà che si dimentica: se la schermata legge uno
  specchio che solo il pull aggiorna, una scrittura riuscita non produce **niente di visibile**.
  `queueOperation` spinge e basta. Ogni azione nuova sul tracking deve chiudersi con un
  `pullTrackingState()`, e ogni azione che tarda più di mezzo secondo deve dirlo sullo schermo,
  altrimenti l'utente la ripete.
- **Il `default` di una mappa di strategie è una decisione, anche quando non la si prende.** Le due
  viste di §9.2 sono finite in `lastWriteWins` per omissione, che le confronta per `updated_at` —
  che una delle due non ha. Aggiungere una tabella al pull significa aggiungerla anche a
  `TableConflictMapping`, sempre.
- **Una nuova strada in una funzione vecchia richiede un ingresso nuovo, non un adattatore.**
  `catalog-resolve` era interamente costruita attorno agli id TVDB dell'export. Il client ha id
  TMDB da sempre, e per lui `/find` non è inutile: è impossibile. Costruire un id TVDB finto per
  poterci passare sarebbe stato il modo sbagliato; `show_ids` è quindici righe e riusa
  `populateShow` e `filterShowsNeedingRefresh` così com'erano.

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
supabase/tests/run.sh                      # Postgres usa-e-getta, migration x2, 80 asserzioni
python3 test_oracle.py                     # oracolo, 31 test
cd supabase/functions/catalog-resolve && deno test            # logica pura, 28 test
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
3. **Rifiuti veri in `sync_rejected_mutations`**, ancora aperti al 2026-07-31: `lists` con
   `constraint_23505` su `idx_lists_one_active_default_per_user_type` (4 occorrenze oggi, 6 fra il
   27 e il 29 luglio) — il client prova a ricreare una lista di default che esiste già — e
   **`list_items` con `list_not_owned`** (1 occorrenza), che è il ramo aggiunto da
   `apply_mutations_list_ownership` e che nessuno ha ancora guardato. Nessuno dei due riguarda il
   tracking: dopo il collaudo della migrazione, `watch_events` e `tv_show_state` non compaiono in
   quella tabella.
4. **`delete-user` cancella 5 tabelle su ~30** (audit §3b) e `profiles.id` non ha
   `ON DELETE CASCADE`: cancellare un utente fallisce se non si toglie prima il profilo. È materia
   GDPR.
