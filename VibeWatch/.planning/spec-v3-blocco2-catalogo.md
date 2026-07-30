# Blocco 2 — Catalogo condiviso e risoluzione TVDB→TMDB

> SPEC v3 §3.1 e §6. Aggiornato: 2026-07-30. **Non ancora deployato.**

## Cosa contiene

| Artefatto | File |
|---|---|
| Schema catalogo + `is_special_episode()` | `supabase/supabase/migrations/20260730000000_create_tmdb_catalog.sql` |
| Edge Function | `supabase/functions/catalog-resolve/index.ts` |
| Logica pura, testata | `supabase/functions/catalog-resolve/resolution.ts` + `resolution_test.ts` |

Tre tabelle condivise fra tutti gli utenti — `tmdb_shows`, `tmdb_episodes`, `tvdb_tmdb_map` — con
lettura pubblica e **nessuna policy di scrittura**: solo `service_role` popola il catalogo, cioè
`catalog-resolve`. Sono dati pubblici, non personali, e lasciarli scrivere ai client sarebbe
vandalismo gratuito su righe che vedono tutti.

## Verificato in locale

- La migration gira su PostgreSQL 18 e **è rieseguibile** senza errori.
- I vincoli tengono: una riga `found` che non punta a niente, un episodio `found` senza
  stagione/episodio e un `entity_type` fuori vocabolario vengono rifiutati.
- Gli upsert che fa la funzione (`on conflict (tvdb_id, entity_type)` e sulla PK degli episodi)
  si comportano come previsto; la cancellazione di una serie porta via i suoi episodi.
- **RLS**: un ruolo con i grant di default di Supabase legge il catalogo e non riesce a scriverlo.
- `deno check` pulito e **23 test** verdi su `resolution.ts`.

Non verificato: nessuna chiamata reale a TMDB, nessun deploy. Servono la chiave e il progetto.

## Cosa serve per deployare

1. **Applicare la migration** (SQL Editor o `supabase db push`).
2. **Il segreto `TMDB_API_KEY`** deve esistere per questa funzione:
   `supabase secrets set TMDB_API_KEY=...` (le altre funzioni già lo usano, quindi in genere c'è
   già a livello di progetto).
3. **Deployare** `catalog-resolve` lasciando `verify_jwt` attivo: §6 vuole il JWT utente, non la
   publishable key come `youtube-search`. La funzione valida comunque il token per conto suo.
4. **Riavviare PostgREST** (Settings → API) perché la schema cache veda le tre tabelle nuove.

Smoke test, con un JWT utente valido:

```bash
curl -X POST 'https://<project>.supabase.co/functions/v1/catalog-resolve' \
  -H "Authorization: Bearer $USER_JWT" -H 'Content-Type: application/json' \
  -d '{"entities":[{"tvdb_id":121361,"entity_type":"series"}]}'
```

Atteso: `resolution: "found"`, `tmdb_show_id: 1399` (Game of Thrones), e `tmdb_episodes` popolata.
La seconda chiamata identica deve rispondere con `cache_hits: 1` e `upstream_calls: 0`.

## Decisioni prese qui, che la spec non fissava

- **Un id che TMDB conosce sotto un altro tipo diventa `ambiguous`, non viene risolto.** Gli id
  TVDB sono unici solo dentro il proprio spazio, quindi lo stesso numero può essere sia una serie
  sia un episodio. Indovinare è il modo in cui la cronologia di qualcuno finisce su una serie che
  non ha mai visto.
- **TTL differenziato**: 90 giorni per una serie conclusa e non più in produzione, 7 per tutte le
  altre. Una serie finita non cambia più.
- **Budget**: 600 chiamate/ora per utente e 50.000/giorno globali, sul contatore già esistente
  (`api_proxy_budget`, provider `tmdb`). Non razionano una quota scarsa — TMDB non ne pubblica una
  — ma limitano un loop impazzito del client. Il per-utente è sull'id dell'utente, non sull'IP:
  qui il JWT c'è, quindi l'identità è reale.
- **Deadline di 20 s per invocazione.** La risoluzione è un job a checkpoint (§7.2): la funzione
  fa quello che riesce, restituisce `remaining` e il chiamante torna. Meglio che essere uccisa a
  metà batch.

## Cosa manca ancora (non è blocco 2)

- La preferenza utente `count_specials_in_progress` (§1.3): arriva col blocco 3, insieme al
  calcolo del progresso che è l'unico posto che la legge.
- Il job che rinfresca le serie scadute (`next_refresh_at <= now()`): l'indice c'è, lo scheduler
  no. Va con il `pg_cron` del blocco 3 (§3.5).
- Le 4 divergenze aperte dell'oracolo (vedi `spec-v3-oracle.md`): si chiudono qui sopra, leggendo
  la numerazione vera da TMDB per `tvdb_episode_id`, appena la mappa è popolata.
- **Un harness SQL.** Il blocco 3 aggiunge `recompute_tv_show_state`, un trigger e la definizione
  di `backlog_since`: logica vera in SQL, che va testata. Le verifiche di questo blocco le ho
  fatte su un Postgres usa-e-getta; per il blocco 3 conviene un file di test versionato.
