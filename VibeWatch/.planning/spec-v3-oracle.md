# Oracolo dell'import TV Time — stato delle divergenze

> Blocco 1 di SPEC v3 §12. Aggiornato: 2026-07-30.
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
| Serie con stato TV Time | 467 |
| **Serie che combaciano** | **399** |
| **Serie che divergono** | **31** |
| Serie con stato ma senza eventi | 37 |

Il dedup di §7.3 (v2 vince, da v1 solo gli `tvdb_episode_id` assenti da v2) toglie 15.906 eventi
duplicati: senza di esso il conteggio ricalcolato è gonfiato e serie come One-Punch Man divergono
per la sola sovrapposizione dei due file.

## Le 31 divergenze, per causa

Ogni divergenza porta nel fixture la sua `cause`, derivata dai numeri e non ipotizzata
(`comparison.cause_descriptions` ne contiene la descrizione).

| Causa | Serie | Stato |
|---|---:|---|
| `tvtime_counter_drift` | 16 | **Accettata.** Nessuna spiegazione strutturale, scarto ≤ 2. `ep_watch_count` è un contatore denormalizzato aggiornato per anni; il log degli eventi è la fonte migliore. VibeWatch si fida degli eventi. |
| `specials_counted_by_tvtime` | 6 | **Accettata.** Includendo gli speciali il conteggio coincide: TV Time li teneva nel totale della serie, §1.3 li tiene fuori dal progresso. Es. Spartacus 39 = 33 + 6 speciali, Doctor Who 67 = 63 + 4. |
| `tvtime_counted_episode_ids` | 4 | **Accettata.** La serie ha più `tvdb_episode_id` distinti che coppie (stagione, episodio): numerazione assoluta contro numerazione per stagione. Es. Digimon 253 id → 107 coppie, Pokémon 999 → 992, Money Heist 48 → 42, Dragon Ball Super 135 → 132. Contare le coppie è il comportamento corretto. |
| `rewatches_counted_by_tvtime` | 1 | **Accettata.** Il conteggio torna sommando i rewatch: TV Time contava le visioni, non gli episodi distinti. |
| `episode_id_collision_partial` | 2 | **DA RISOLVERE.** Mario (34 vs 51, 66 id su 51 coppie), Attack on Titan (110 vs 112, 114 id su 112 coppie): ci sono id duplicati, ma il conteggio di TV Time non coincide né con gli id né con le coppie. |
| `needs_manual_review` | 2 | **DA RISOLVERE.** One-Punch Man (36 vs 44, 51 id, 7 speciali) e Billionaires' Bunker (2 vs 8). Nessuna regola li spiega. |

**Le 4 serie da risolvere sono la lista di lavoro prima del rilascio** (§8). Vanno chiuse quando
esiste la risoluzione TVDB→TMDB (blocco 2): la numerazione corretta si legge da TMDB per
`tvdb_episode_id`, mai dedotta dai numeri di stagione/episodio.

`test_oracle.py` fallisce se le divergenze senza spiegazione superano quelle note: una regressione
del parser che ne introduce di nuove non passa in silenzio.

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
- **Risoluzione TVDB→TMDB.** Gli id nel fixture sono TheTVDB: la mappa arriva col blocco 2.
