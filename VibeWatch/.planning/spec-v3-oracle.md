# Oracolo dell'import TV Time — stato delle divergenze

> Blocco 1 di SPEC v3 §12. Aggiornato: 2026-07-31 — **tutte le divergenze sono chiuse**.
> Rigenerare con `python3 build_oracle.py <cartella_export> oracle_fixture.json`,
> verificare con `python3 test_oracle.py`.

## Cos'è

`build_oracle.py` trasforma un export GDPR di TV Time in `oracle_fixture.json`, che contiene
insieme gli **eventi grezzi** da importare e lo **stato che TV Time aveva già calcolato**
(`ep_watch_count`, `most_recent_ep_watched`). L'import di VibeWatch deve ricalcolare quello stato
dagli eventi: dove i due coincidono, l'import è corretto per costruzione.

`test_oracle.py` blocca la baseline e le invarianti. È il test che permette di iterare
sull'importer fino a verde invece di produrre codice plausibile ma non validato.

## Baseline sull'export reale in repo

| | |
|---|---:|
| Eventi v2 | 21.322 |
| Eventi v1 tenuti (episodi assenti da v2) | 22 |
| Eventi v1 scartati come duplicati | 15.906 |
| Righe v1 inutilizzabili (senza id) | 139 |
| Eventi totali nel fixture | 21.344 |
| di cui rewatch (righe `rewatch-episode`) | 155 |
| di cui speciali (stagione 0) | 613 |
| di cui **con numerazione persa** (`episode_number = 0`) | 195 |
| Serie con stato TV Time | 467 |
| **Serie che combaciano** | **389** |
| **Serie che divergono, tutte con una causa** | **41** |
| di cui senza spiegazione | **0** |
| Serie con stato ma senza eventi | 37 |

Il dedup di §7.3 (v2 vince, da v1 solo gli `tvdb_episode_id` assenti da v2) toglie 15.906 eventi
duplicati: senza di esso il conteggio ricalcolato è gonfiato e serie come One-Punch Man divergono
per la sola sovrapposizione dei due file.

## Perché la baseline è 389/41 e non più 399/31

Non è una regressione: prima l'oracolo misurava la cosa sbagliata.

Il conteggio ricalcolato ora è **ciò che VibeWatch produrrà** — coppie (stagione, episodio)
distinte, stagione 0 fuori dal progresso come impone §1.3. Prima leggeva la specialità dal flag
`is_special` dell'export, che TV Time popola solo sui record recenti. Su **10 serie** questo
faceva combaciare l'oracolo con TV Time mentre la produzione, che filtra con
`is_special_episode(season_number)`, avrebbe prodotto un altro numero: erano coincidenze per il
motivo sbagliato, e nascondevano proprio la divergenza che §1.3 introduce di proposito.

**Il caso di controllo è Game of Thrones**, la sola serie di cui il catalogo in produzione è
popolato: TMDB le dà 373 episodi di cui 300 speciali, `recompute_tv_show_state` conta **73**,
l'oracolo diceva **74**. Ora dice 73. C'è un test dedicato.

Le 41 divergenze si dividono così:

| Causa | Serie | Stato |
|---|---:|---|
| `specials_counted_by_tvtime` | 18 | **Attesa per progetto.** Lo scarto è esattamente il numero di speciali. §1.3 li tiene fuori dal progresso, TV Time no. |
| `tvtime_counter_drift` | 12 | **Accettata.** Scarto ≤ 2, nessuna spiegazione strutturale. `ep_watch_count` è un contatore denormalizzato aggiornato per anni: il log degli eventi è la fonte migliore. |
| `numbering_lost_by_tvtime` | 9 | **Attesa.** Lo scarto è il numero di episodi con `episode_number = 0`. La fase `resolving` li recupera da TMDB per `tvdb_episode_id`; ciò che resta va nel report di §7.4. |
| `rewatches_counted_by_tvtime` | 1 | **Accettata.** TV Time contava le visioni, non gli episodi distinti. |
| `backfill_missed_by_tvtime_counter` | 1 | **Chiusa.** Vedi Billionaires' Bunker più sotto. |

## Come si assegna una causa, adesso

Non più per categoria scelta a occhio: **per somma di termini misurati**. Lo scarto fra
`ep_watch_count` e il conteggio ricalcolato va chiuso da una combinazione di quantità osservabili,
e quella combinazione finisce nel fixture come campo `explained_by` — è la prova aritmetica della
causa, non la sua etichetta. Se nessuna combinazione lo chiude e lo scarto supera 2, la divergenza
si dichiara **scoperta** e il test fallisce: `MAX_UNRESOLVED` sta a **0** apposta.

I termini:

| Termine | Cos'è |
|---|---|
| `specials_by_season` | le coppie in stagione 0 |
| `specials_by_flag` | quelle che il **flag** dell'export chiama speciali, al netto di quelle che chiama speciali in stagioni numerate |
| `numbering_lost` | gli `tvdb_episode_id` distinti con `episode_number = 0` |
| `rewatches` | le visioni successive alla prima |
| `backfill_at_counter_creation` | le coppie riempite da un `fill-previous` avvenuto **prima** che nascesse la riga contatore |

**Perché i termini sugli speciali sono due.** Perché TV Time non è coerente con se stesso:
Spartacus e Doctor Who contano gli speciali per stagione, Naruto Shippuden e X Factor per il
proprio flag. `ep_watch_count` è stato incrementato per un decennio da versioni diverse dell'app
e le due ere hanno lasciato entrambe il segno. Sono alternative, mai addendi: sommarli conterebbe
due volte la stessa stagione 0 e produrrebbe spiegazioni che tornano per caso.

## Le 4 divergenze che erano "da risolvere"

Erano il blocco prima del rilascio (§8). Tutte chiuse, e due di esse erano **difetti veri del
parser**, non della sola comparazione: valevano su 12 serie e 195 eventi, non solo su queste.

### Mario — 34 vs 51 → **coincide**

66 eventi: 16 in stagione 0, 18 in S1, 16 in S2, e **16 record in S3 tutti con
`episode_number = 0`**. Quei 16 collassavano su un'unica coppia `(3, 0)`: 16 episodi distinti
diventavano uno. Con la numerazione trattata come persa, il progresso è 18 + 16 = **34**, cioè
esattamente `ep_watch_count`.

### One-Punch Man — 36 vs 44 → **coincide**

51 eventi, 15 in stagione 0. Di quei 15, **8 portano `is_special = false`** perché sono record
del 2019 e 2021, scritti prima che TV Time aggiungesse la colonna; i 7 con il flag sono tutti
`bulk_type = season` del 2025. Leggendo il flag, 8 speciali entravano nel progresso. Con §1.3
il progresso è 12 + 12 + 12 = **36**, cioè `ep_watch_count`.

### Attack on Titan — 110 vs 112 → **divergenza attesa**

Entrambi i difetti insieme: 21 eventi in stagione 0 (tutti senza flag) e 4 con numerazione persa.
Il progresso corretto è **89**; TV Time conta 110 = 89 + 21 speciali. Passa nella categoria
`specials_counted_by_tvtime`, la stessa di altre 17 serie, e non è più un caso da esaminare.

### Billionaires' Bunker — 2 vs 8 → **spiegata**

La riga contatore nasce alle `2025-10-11 20:37:56`, **lo stesso secondo** dei 6 eventi
`fill-previous` che marcano S1E1-E6: è partita da 1 invece che da 7. Gli altri due eventi (E7 nello
stesso istante, E8 il giorno dopo) portano il contatore a 2, mentre gli 8 episodi sono tutti nel
log con id distinti e numerazione consecutiva.

**Verificata come eccezione, non come regola.** L'ipotesi "TV Time non conta i `fill-previous`" è
stata provata su tutto l'export e **smentita**: delle 132 serie con eventi `fill-previous`, 131 li
contano correttamente. Ristretta alle 15 serie in cui il backfill precede la nascita del contatore
— la forma esatta di Bunker — 14 li contano correttamente. Il termine si applica solo quando il
backfill precede il contatore, e c'è un test che verifica che con un contatore più vecchio non
scatti.

## `episode_number = 0` non è l'episodio zero

È la scoperta che vale più delle quattro serie messe insieme. Nel CSV grezzo quei record hanno
`ep_no: 0`, `runtime: 0` e un `updated_at` del 2023: sono righe rimaste orfane di un episodio
riorganizzato su TVDB. **TV Time aveva perso la numerazione, non l'episodio.**

Sono **195 eventi su 12 serie**, e Digimon da sola ne ha 149 — motivo per cui la sua divergenza
(253 vs 107) era stata attribuita alla numerazione assoluta contro quella per stagione: la causa
vera è un'altra, ed è misurabile.

| Serie | Eventi senza numero |
|---|---:|
| Digimon: Digital Monsters | 149 |
| Mario | 16 |
| Pokémon | 8 |
| Money Heist | 7 |
| Attack on Titan, Dragon Ball Super | 4 ciascuna |
| One Piece | 2 |
| Kuroko's Basketball, Sense8, 12 Monkeys, Lost, Antonino Chef Academy | 1 ciascuna |

Fonderli per `(stagione, episodio)` è la stessa classe di errore contro cui mette in guardia §7.3:
si inventano visioni che non ci sono state. L'identità vera è `tvdb_episode_id`, e la fase
`resolving` la risolve su TMDB recuperando la numerazione (§6). Ciò che resta irrisolto è
materiale obbligatorio del report di §7.4.

## Conseguenze per chi scrive la fase 4 (`writing`)

1. **`watch_events.is_special` va derivato dalla stagione risolta da TMDB**, non dal record di
   staging. Il parser ora scrive la specialità corretta rispetto all'export, ma dopo il
   `resolving` la stagione autorevole è quella di TMDB — ed è quella che
   `recompute_tv_show_state` userà. Se le due divergono, la colonna mente alla funzione che le sta
   accanto.
2. **Il flag originale non si perde**: `tvtime_is_special_raw` va in
   `external_ref->>'tvtime_is_special'`. Non è rumore — è il criterio con cui TV Time contava, e
   serve a rispiegare una divergenza senza rifare l'analisi.
3. **Un evento con `numbering_known = false` e non risolto non è scrivibile**: il CHECK
   `watch_events_shape` pretende `season_number` e `episode_number` non nulli. Va nel report come
   non riconosciuto, mai scritto con un numero inventato.

## Serie con stato ma senza eventi (37)

Righe `user-series` senza nessun `watch-episode` corrispondente: serie seguite o messe da parte
senza mai averne visto un episodio. Non sono un errore — sono `not_started` / `for_later` (§3.4) e
l'import deve produrre la riga di stato senza eventi.

## Voti (§7.5)

La decodifica confermata dalla spec regge sul fixture: 295 valori ≤ 5 (stelle, convertite in
`user_ratings.rating = X * 2`), 83 valori ≥ 13 (id di reaction, conservati grezzi), 2 righe con
`vote_key` malformato marcate `undecodable`. **Nessun valore nella banda 6-12**: se ne comparisse
uno, la regola di separazione andrebbe rivista.

La distribuzione (255 volte `3`, 35 volte `1`) è un fatto su questo utente, non un errore di
decodifica: i file legacy mostrano anche 2, 4 e 5. Nessuna euristica di normalizzazione.

## Cosa il fixture non copre

- **Film.** L'export ne contiene, il fixture oggi tiene solo gli episodi.
- **`lists-prod-lists.csv`** (candidati per i Favorites, §7.1): serve al blocco 9, non al 6.
- **Risoluzione TVDB→TMDB.** Gli id nel fixture sono TheTVDB. La mappa esiste (blocco 2), ma il
  fixture resta volutamente **pre-risoluzione**: è la fotografia di ciò che l'export dice da solo.
  I 195 eventi senza numerazione sono l'esempio — nel fixture restano senza numero, nella pipeline
  vera TMDB glielo ridà.
