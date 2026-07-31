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

## §13.6 è soddisfatto — misurato sul dispositivo, 2026-07-31

Il blocco 7 è chiuso. Due misure su dispositivo, entrambe dentro il budget:

| Percorso | Totale | di cui lettura | Budget |
|---|---:|---:|---:|
| **A freddo** — tap, lettura da SQLite, contenuto a schermo | **208,9 ms** | 34,1 ms | 300 ms |
| A schermata già popolata — il disegno da solo | 147,5 ms | — | 300 ms |

**Il numero che conta è 208,9 ms**: è il percorso che §13.6 descrive — "renderizza da cache locale,
zero chiamate di rete, sotto i 300 ms". Margine ~30%. Il secondo caso capita perché il ViewModel si
ricarica anche su `syncEngineCompleted`, quindi aprendo la tab le sezioni possono esserci già: è
una misura valida ma risponde a una domanda più facile, e va letta come tale.

**Dove sta il tempo.** La lettura è 34 ms, il disegno gli altri 175. Il collo di bottiglia **non è
SQLite**: è SwiftUI. Se un giorno servisse margine, è lì che va cercato — non nella query, che era
già stata misurata a 0,66 ms di mediana su un DB seminato (i 34 ms sul dispositivo sono la stessa
query a freddo, con la cache delle pagine vuota).

**Cosa questi numeri non dicono.** Sono due campioni, non una distribuzione, e su un dispositivo
solo. Se servisse una misura ripetibile c'è già l'aggancio: `XCTOSSignpostMetric(subsystem:
"com.vibewatch.app", category: "Tracking", name: "TrackingFirstFrame")`. Se le misure fossero state
prese in DEBUG il numero è conservativo — Swift non ottimizzato è più lento, quindi in Release il
margine è maggiore, mai minore.

### Come rifarla

Console.app col telefono collegato, filtro su sottosistema `com.vibewatch.app` e categoria
`TrackingPerf`; poi si apre la tab Tracking. Il log passa da `os.Logger` e non dal `Logger` del
progetto proprio per questo: quello è tutto dentro `#if DEBUG` e in Release non stampa una riga.
In alternativa Instruments, template *Points of Interest*, intervallo `TrackingFirstFrame`.

Per il caso a freddo va chiusa l'app e aperto il Tracking come prima cosa; altrimenti si misura il
disegno e basta. **Se compare `misura abbandonata`**, l'intervallo è troppo lungo per essere un
fotogramma — di solito un rientro sulla tab molto dopo — e non c'è nessun numero da credere.

## La schermata username, provata sul server vero — chiusa il 2026-07-31

Entrambe le modalità verificate sul dispositivo (account `feicaccaunt777@gmail.com`, id
`9b339294-6f14-49a6-b977-693213ae89fb`):

- **conferma**: schermata comparsa perché `confirmed_at` era null, `nakka` precompilato dal
  backfill, la conferma ha scritto `username_confirmed_at` lasciando `username_changed_at` a null
  (confermare il nome invariato non è un cambio);
- **scelta** (dopo l'`update … set username = null, username_confirmed_at = null`): comparsa
  giusta, `nakka` riscelto e salvato; stavolta `username_changed_at` è valorizzato, perché
  null → `nakka` è un cambio vero.

**Due difetti trovati usandola, entrambi corretti e coperti (17 test in `UsernameSetupTests`):**

1. **Ogni nome risultava "già preso".** Non era il server: `username_available` restituisce
   `boolean`, e PostgREST lo serializza come `true`/`false` **nudo** — un frammento JSON di primo
   livello, che `JSONSerialization.jsonObject` senza `.fragmentsAllowed` rifiuta. Il `try?`
   ingoiava il parse fallito e il `?? false` lo spacciava per "occupato", anche sui `true`. Stessa
   famiglia dei fallimenti silenziosi in testa a questo documento, e **i test coi doppi erano verdi
   col difetto dentro**: il `Fake` non passa dal parse. Corretto su due strati:
   `SupabaseService.parseBooleanRPCResponse` (frammento ammesso; una risposta illeggibile **lancia**
   `unexpectedResponse` invece di diventare un "no") e il ViewModel, dove un errore di verifica ora
   mostra `username.error.checkFailed` (chiave nuova, tradotta in tutte e 20 le lingue) invece di
   "già preso". Gli altri `callRPC` sono salvi perché ricevono oggetti jsonb, non scalari.
2. **Oltre i 20 caratteri diceva "disponibile".** `normalizeTyping` tagliava a 20 con `.prefix`,
   quindi si verificava — e si sarebbe salvato — il prefisso: un nome mai digitato, col
   suggerimento a fianco che diceva "da 3 a 20". Era la stessa riscrittura muta che il commento
   della funzione dichiara di non fare per i caratteri. Tolto il taglio: il 21° carattere resta nel
   campo e diventa un `.tooLong` visibile, pulsante spento, niente giro di rete.

## `user_follows` + `search_users` — in produzione dal 2026-07-31

Migration `20260801130000_user_follows_and_search.sql`, applicata e verificata (`proacl`, grant,
trigger, ricerca di fumo su `nakka`). Il commento in testa alla migration spiega i due perché;
qui il riassunto:

| | |
|---|---|
| `user_follows` | forma di §3.6: PK `(follower_id, followee_id)`, niente id sintetico, soft delete come `user_blocks` |
| RLS | si vedono le righe in cui si è uno dei due capi; **scrive solo il follower** (insert e soft delete) |
| Indici | la PK copre "chi seguo", `user_follows_followee` (parziale) copre "chi mi segue" |
| `search_users(p_query, p_limit)` | legge da `public_profiles`, `ilike` sugli indici GIN trigram esistenti, similarità solo per l'**ordine**; `%`/`_`/`\` nella query sono caratteri, non jolly |
| Blocchi | esclusi **nei due versi** dalla ricerca, e — lezione di `username_reserved` — anche in **scrittura**: il trigger `user_follows_blocked` rifiuta il follow attraverso un blocco |
| Chi chiama | `search_users` solo `authenticated` (verificato su `proacl`); la funzione del trigger nessun ruolo client |

**Perché `security definer`, due volte.** `user_blocks` ha `blocks_select_own`: il verso "mi ha
bloccato" è invisibile al chiamante per costruzione. Un invoker vedrebbe metà dei blocchi — nella
ricerca mostrerebbe a B chi l'ha bloccato, e nel trigger lascerebbe passare il follow. **Provato
rompendo**: rimessi invoker, la suite fallisce su "a non segue chi l'ha bloccato".

**27 asserzioni nuove in `social_test.sql` (82 → 109).** Il harness ora ricrea anche
`user_blocks` (la sua migration precede il repo, forma verificata su `pg_policy` in produzione)
e `run.sh` ha la migration nuova nella whitelist.

## Il pezzo client — scritto e **provato sul dispositivo** il 2026-07-31

Follow e unfollow verificati fra due account veri (`nakka` → `nicola_sarli_23`): sul server una
riga sola, creata e poi soft-cancellata — stessa riga riusata, union end-to-end via outbox, zero
duplicati.

**Il collaudo ha trovato il terzo difetto della giornata, e ha la stessa forma degli altri due.**
Il proprio profilo, raggiungibile dalla ricerca (e va bene così: "come appaio?" merita risposta),
mostrava il pulsante "Segui". Il tap accodava un self-follow; il CHECK `follower <> followee` lo
respingeva **come rifiuto muto** in `sync_rejected_mutations` (`constraint_23514`, registrato
alle 18:32:23 — è la prova, ed è spiegato); la schermata tornava com'era. Fallimento invisibile
che invita a ripremere. Tre correzioni: sul proprio profilo il pulsante **non esiste** (al suo
posto "Sei tu.", chiave nuova nelle 20 lingue), `isOwnProfile` fa da guardia anche in
`toggleFollow`, e `SocialActions` rifiuta il self-follow con un errore vero **prima** di
accodare — la difesa in profondità per ogni chiamante futuro. Due test lo fissano.

**Il sync di `user_follows`, con le sue tre specificità:**

- whitelist `SQLiteTable` + migration SQLite **10** (chiave = la coppia, niente id sintetico) +
  pull-list + `TableConflictMapping` a **`union`** (mai nel `default`, lezione delle viste);
- il filtro del pull non è `user_id` (che non esiste): `or(follower_id.eq.X,followee_id.eq.X)`;
- l'ordinamento di pagina usa **entrambe** le colonne della coppia — nessuna da sola è unica nel
  sottoinsieme dell'utente, e un ordine non totale fa sovrapporre le pagine (§5);
- la risoluzione dei conflitti cerca la riga locale per **chiave composita**
  (`getKeyColumns`/`fetchLocalRecord(table:row:)`): cercare per il solo `follower_id`
  confronterebbe follow diversi fra loro.

**Il ramo `user_follows` in `apply_mutations` è in produzione** (migration `20260801140000`),
applicato per **splice sul `prosrc` reale** con tre guardie md5 — mai col file in cartella. Il
cancello d'identità ora confronta la colonna giusta per tabella (`follower_id`, non `user_id`).
Collaudato con transazione fatta fallire: follow, rigioco idempotente, unfollow soft, forgiato
respinto, bloccato respinto dal trigger (`constraint_23514`), DELETE col followee in `id`.

**La UI:** `UserSearchView` (tre stati distinti: invito / nessuno / **ricerca fallita con
riprova** — mai schiacciati l'uno sull'altro), `PublicProfileView` (header §9.3, contatori dal
server via `get_public_profile`, pulsante segui con stato in volo e rilettura dopo la scrittura —
la metà che si dimentica), `SocialActions` (l'unico posto che scrive `follower_id`, come
`TrackingActions` per `user_id`), ingresso da `ProfileView` ("Trova amici"). 12 chiavi nuove
tradotte nelle 20 lingue. 11 test in `SocialProfileTests` (file **registrato a mano nel
pbxproj**, nei soliti quattro punti).

Il blocco 8 è **chiuso** (manca solo la prova su dispositivo del login con username, sotto). Il
prossimo blocco è il **9** (favorites, rating in stelle, stats, diario), che si appoggia a
`get_public_profile` per la parte pubblica.

### Il login con username — chiuso il 2026-07-31, Edge Function `login-with-username`

La strada vecchia era doppiamente indifendibile: `getEmailFromUsername` cercava `profiles.email`
con un **ilike fuzzy su `display_name`** — un endpoint di raccolta indirizzi, se la RLS non
l'avesse bloccato facendo fallire ogni login con username. Rimossa.

Ora risoluzione e autenticazione sono **atomiche** nella funzione (`verify_jwt` spento al deploy:
il chiamante non ha ancora una sessione, è il login): username → email con la chiave di servizio →
grant password verso GoTrue → la sessione torna al client, che la installa con `setSession`.
L'email non lascia mai il server senza la password giusta. Tre difese, ciascuna col suo perché:

1. **ogni fallimento di credenziali risponde `invalid_credentials`, identico** — distinguere
   "username inesistente" da "password sbagliata" sarebbe un oracolo sugli username (uno username
   fuori forma pure: è una credenziale sbagliata, non una richiesta malformata);
2. **per uno username inesistente il giro verso GoTrue si fa comunque**, con un'email esca su TLD
   `.invalid` (RFC 2606) — senza, la latenza direbbe quali username esistono;
3. **tetto per IP** (30/ora, provider `auth_login` in `api_proxy_budget`, migration
   `20260801160000`): GoTrue da dietro la funzione vede l'IP della funzione, non del client,
   quindi il suo rate limiting sul brute force non basta più. Il 429 al client dice "troppi
   tentativi" (`auth.error.tooManyAttempts`, 20 lingue): non rivela niente e non confonde.

**Collaudato via HTTP in produzione** su utente usa-e-getta (creato con `crypt` e colonne token a
`''`, cancellato alla fine, residui zero): credenziali giuste → sessione **spendibile** (REST
sotto RLS risponde con la propria riga); maiuscole e spazi normalizzati; password sbagliata e
username inesistente → **corpi identici**; campo mancante → `invalid_request`; senza chiave →
401; il budget conta i tentativi di credenziali e **non** le richieste malformate. Nota emersa:
la **legacy anon key è disabilitata** sul progetto — la funzione parla con GoTrue con la chiave
dell'ambiente e funziona, ma qualsiasi codice che si aspetti una anon key JWT valida è già rotto
oggi.

6 test Deno sulla logica pura (`deno test supabase/functions/login-with-username/`).
**Da provare sul dispositivo**: login con `@username` + password da un account email (gli account
OAuth una password non ce l'hanno — per loro il campo resta email o niente).

## Il blocco 8, quello che è già in produzione

Tre migration applicate e verificate: schema (`20260801100000`), backfill (`20260801110000`),
`set_username` (`20260801120000`). Più il pezzo iOS.

| | |
|---|---|
| `profiles` | `username` (citext), `bio`, `is_profile_public`, `username_changed_at`, `username_confirmed_at` |
| Unicità | indice **parziale**: un profilo cancellato non tiene occupato il nome per sempre |
| `public_profiles` | sei colonne — `id, username, display_name, avatar_url, bio, created_at`. Niente email, niente `fcm_token`, niente billing |
| Generazione | `username_seed` (pura), `username_available` (l'unica che il client può chiamare), `suggest_username` |
| Scrittura | `set_username(text)` → `jsonb`: `{ok, username, changed}` oppure `{ok:false, reason}` con `taken` / `reserved` / `invalid_format` |
| `username_reserved` | 64 nomi, RLS senza policy: l'elenco non si legge dal client |
| Backfill | **295 assegnati, 19 lasciati null, 295 univoci, zero fuori formato, zero già datati** |
| iOS | `UsernameRules` (pura), `UsernameSetupViewModel`, `UsernameSetupView`, sheet agganciato in `VibeWatchApp.swift` dopo il sync di avvio |

**`username_confirmed_at` è il segnale che fa comparire la schermata**, e sta sul server apposta:
un flag locale si perderebbe alla reinstallazione e la schermata ricomparirebbe a chi aveva già
scelto. Nullo significa "assegnato dal backfill e mai visto da chi lo porta".

**I riservati valevano solo per chi li chiedeva gentilmente.** `username_reserved` la consultavano
`username_available` e `suggest_username`, cioè le due funzioni che *propongono*. Niente la
consultava in **scrittura**: `profiles_update_own` permette al proprietario di aggiornare la
propria riga, e il CHECK sul formato non sa niente dei nomi riservati — un PATCH diretto su
`profiles.username = 'admin'` passava tutto e si prendeva `@admin`. Ora lo ferma il trigger
`profiles_username_changed`, che è l'unico punto non scavalcabile: un CHECK non può leggere
un'altra tabella. C'è un test che, rimettendo il difetto, fallisce.

**Perché `set_username` è un'RPC e non un PATCH.** Tre ragioni pratiche: il client non può leggere
`username_reserved` (e non deve), quindi da solo mostrerebbe "occupato" al posto di "riservato";
fra il controllo di disponibilità e la scrittura c'è una finestra in cui un altro può prendere lo
stesso nome, e qui la chiude l'indice unico restituendo un esito invece di un `23505` da
interpretare; e `username_confirmed_at` si scrive lì e solo lì, insieme al nome.

**Cosa il client duplica e cosa no.** Duplica la **forma** (`UsernameRules.pattern`, identica al
CHECK) per rispondere mentre si digita senza un giro di rete per carattere. **Non** duplica
l'elenco dei riservati: non può leggerlo, e indovinarlo sarebbe la copia che diverge davvero.
`normalizeTyping` abbassa le maiuscole e toglie gli spazi ai bordi — errori di battitura — ma non
sostituisce il resto: trasformare `mario.rossi` in `mario_rossi` di nascosto darebbe all'utente un
nome che non ha scelto. Quello lo fa `username_seed`, che serve a *proporre*.

**La simulazione prima della scrittura ha trovato una fuga.** Derivare lo username dalla parte
locale dell'email sembrava il ripiego ovvio per chi ha un nome non riducibile a `[a-z0-9_]` (nomi
cinesi, cirillici). Sui dati veri: dei 18 profili che ci sarebbero ricaduti, **9 hanno un indirizzo
`@privaterelay.appleid.com`** — la parte locale è il token di relay di Apple, e pubblicarla come
`@8xp9vsbgxm` ricostruisce un indirizzo contattabile — e 3 hanno un locale che è un **numero di
telefono** (`@qq.com`, `@139.com`). Tutta §3.7 esiste per tenere l'email fuori dalla superficie
pubblica; farcela rientrare dal ripiego sarebbe stato il modo più silenzioso di annullarla.
`suggest_username` esiste come funzione che **non scrive** proprio per rendere possibile quella
simulazione.

**Il trigger avrebbe annullato la propria correzione.** Il backfill data 295 profili come "username
appena cambiato", il che è vero alla lettera e falso nella sostanza — quel nome non l'ha scelto
l'utente. Con un futuro limite di frequenza, i 295 nascerebbero bloccati proprio sulla conferma che
§3.7 pretende. Rimetterlo a null con una UPDATE **non funziona**: `profiles_username_changed` è
`before update` e sul ramo "username invariato" riscrive il vecchio valore sopra il null. Il
backfill spegne il trigger, e c'è un test che documenta perché.

### La sonda ha sbagliato due volte, e la seconda l'ha trovata l'esecuzione

**Primo giro.** La sentinella stava fuori dalla condizione sul contenuto, quindi la sequenza era:
`begin()`, `isLoading = true`, SwiftUI ridisegna, la `List` compare **vuota** — i dati sono ancora
dentro l'`await` — e il capolinea scattava lì. Il `61,9 ms` era stato attribuito all'account senza
storico; era invece strutturale, e avrebbe mentito anche con 24 serie. Corretto mettendo la
sentinella dentro `if !sections.isEmpty` e aggiungendo una guardia che scartava la misura se
`dataReady` non era ancora arrivato.

**La guardia era sbagliata, e l'esecuzione l'ha detto subito:**

```
§13.6 misura scartata: primo fotogramma prima dei dati, sarebbe stata su schermata vuota
§13.6 dati pronti in 133.5 ms (24 righe)
§13.6 OLTRE IL BUDGET: totale 40500.6 ms (dati + disegno 40367.1 ms) — budget 300 ms
```

Due cose insieme, ed entrambe contavano:

1. **Il capolinea prima di `dataReady` non è un errore.** Il ViewModel si ricarica anche su
   `syncEngineCompleted`, quindi quando l'utente apre la tab le sezioni **possono esserci già**.
   In quel caso il contenuto è a schermo subito e la risposta giusta di §13.6 è "quasi zero": la
   guardia scartava proprio la misura buona. `dataReady` è tornato a essere informativo.
2. **Scartare senza disarmare è peggio che non scartare.** Il cronometro restava armato, e
   quaranta secondi dopo — rientrando sulla tab — un secondo `onAppear` lo chiudeva stampando
   `40500.6 ms` come se fosse un tempo di disegno. Un numero assurdo è peggio di nessun numero,
   perché qualcuno potrebbe crederci.

Ora: si **disarma sempre**, e c'è una soglia (`abandonAfterMs = 5 s`) che scarta ciò che non può
essere un fotogramma. Larga di proposito — deve buttare l'assurdo, non arbitrare fra "lento" e
"molto lento": un 900 ms vero va visto, e c'è un test che lo verifica.

**Il primo test del disarmo passava anche col difetto rimesso.** Chiamava due volte
`firstFrameRendered()` con lo stesso istante: la seconda veniva scartata di nuovo dalla soglia, e
la guardia mancante non cambiava niente. Riscritto per chiudere con un intervallo *plausibile* —
se il cronometro fosse rimasto armato tornerebbe 50 ms. È lo stesso errore contro cui mette in
guardia la testa di questo documento, commesso mentre lo si applicava.

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

- ~~**§13.6 non è ancora verificato**~~ — **fatto**, 208,9 ms a freddo contro 300 di budget. Vedi
  in cima.
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
| 7 | UI Tracking | **chiuso.** Schermata, tab bar e migrazione dello storico in produzione; 971 episodi migrati sul dispositivo dell'autore al primo tentativo; §13.6 misurato a **208,9 ms** su 300; 20 lingue allineate |
| 8 | Username, `public_profiles`, ricerca, follow | **chiuso, tutto in produzione**: schema, backfill, schermata di scelta, `user_follows`, `search_users`, `get_public_profile`, ramo in `apply_mutations`, sync client, UI (provata sul dispositivo) e login con username via Edge Function (collaudato via HTTP; da provare sul dispositivo) |
| 9-10 | Favorites, stats, diario, universal links | da fare |

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
- **`user_follows`** (RLS, trigger `user_follows_blocked` che applica i blocchi in scrittura) e
  **`search_users`** (`security definer`, solo `authenticated`, `proacl` verificato). Dal
  2026-07-31, migration `20260801130000`. Più **`get_public_profile`** (`20260801150000`) e il
  ramo `user_follows` in `apply_mutations` (`20260801140000`, splice sul `prosrc` reale).
- Edge Function **`login-with-username`**, `verify_jwt` spento, con budget per IP
  (provider `auth_login`, 30/ora, migration `20260801160000`).
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
- **Simulare prima di scrivere ha trovato più difetti che rileggere il codice.** Nel blocco 8 due
  su due: la fuga del relay Apple (`suggest_username` non scrive niente **apposta**, così il
  backfill su 314 profili veri si prova con una SELECT) e il trigger che avrebbe annullato la
  propria correzione. Nessuno dei due si vedeva leggendo. Vale la pena costruire le funzioni in
  modo che una prova a vuoto sia possibile, anche quando costa una firma più scomoda.
- **Una lista di eccezioni va applicata dove si scrive, non dove si propone.** `username_reserved`
  era consultata da `username_available` e `suggest_username` — le funzioni che *suggeriscono* — e
  da nessuna parte in scrittura. Chi passava dalla porta principale (un PATCH su `profiles`) si
  prendeva `@admin`. La regola generale: se un vincolo non è esprimibile come CHECK, il posto è un
  trigger, non la funzione gentile che qualcuno *dovrebbe* chiamare.
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
supabase/tests/run.sh                      # Postgres usa-e-getta, migration x2
                                           # tracking_test 80 asserzioni + social_test 82
python3 test_oracle.py                     # oracolo, 31 test
cd supabase/functions/catalog-resolve && deno test            # logica pura, 28 test
cd supabase/functions/login-with-username && deno test        # login con username, 6 test
cd supabase/functions/import-parse   && deno test --allow-read  # parser, 14 test

# Il 15° test del parser (l'apertura dell'archivio) gira solo se gli si dà l'export vero,
# che non è in repo — senza `--allow-env` la suite fallisce sul permesso, non sul codice:
TVTIME_ZIP=~/Downloads/gdpr-data.zip deno test --allow-read --allow-env

# iOS: se la config è incompleta, l'app si ferma all'avvio in DEBUG con l'elenco
# delle chiavi mancanti (Config.validateAtLaunch). Non è un bug: sono i segreti.
xcodebuild test -project VibeWatchApp.xcodeproj -scheme VibeWatchApp \
  -destination 'id=601C4430-6213-49E3-8A4D-3564B2B57E2A'   # 403 test, 3 fallimenti PREESISTENTI

# Deploy di una Edge Function: dalla radice del repo, non da supabase/
supabase functions deploy import-parse --project-ref rqhxhkijzhqivljivirq
```

I 3 test iOS che falliscono (`ConflictResolverTests` x2, `SyncStateMachineTests.testIdleToIdle`)
fallivano già prima di questo lavoro e sono fuori scope. Il conteggio "9 fallimenti" che compare
nel riepilogo non sono nove test: sono gli stessi 3 ripetuti su più configurazioni del piano.

**Un file nuovo sotto `VibeWatchAppTests/` non viene compilato da solo**: va aggiunto al
`project.pbxproj` in quattro punti (`PBXBuildFile`, `PBXFileReference`, figli del gruppo, fase
`Sources`). Altrimenti `-only-testing:` risponde "Executed 0 tests" e conclude TEST SUCCEEDED.

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
- `supabase/tests/social_test.sql` — le 82 asserzioni del blocco 8. Il commento in testa a ogni
  migration di `supabase/supabase/migrations/2026080*` spiega **perché**, non cosa: è lì che stanno
  le ragioni che questo documento riassume
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
