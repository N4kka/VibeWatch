// Rinfresco notturno del catalogo delle serie seguite (Task 4), invocato da `pg_cron` alle 04:00.
//
// **Perché esiste.** `tmdb_episodes` si popola solo quando qualcuno chiede una serie. Dopo, non la
// tocca più nessuno: una serie "ended" ha un TTL a 90 giorni, e una serie rinnovata dopo la
// chiusura non ha proprio chi la richieda. L'episodio nuovo esce, il catalogo non lo sa,
// `refresh_backlog_since()` ricalcola sugli stessi dati di ieri e la serie resta "in pari".
//
// **Cosa fa.** Chiede al database quali serie *seguite* hanno un catalogo mancante o stantio
// (`catalog_shows_needing_refresh`) e le passa a `catalog-resolve` con `show_ids` e
// `force_refresh`, cinquanta per volta. È la stessa strada del riscaldamento, con la stessa
// disciplina di budget (scope `prewarm`): se il tetto è conteso questo lavoro deve perdere.
//
// Autenticazione: solo la chiave di servizio, fail-closed. Non c'è un utente dietro.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) {
    try {
      const k = JSON.parse(s)?.default
      if (k) return k as string
    } catch { /* fall back */ }
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()

/** `catalog-resolve` non ne accetta di più. */
const BATCH = 50
/** Lotti per invocazione: oltre, il muro di wall-clock della funzione taglia a metà il lavoro. */
const BATCHES_PER_INVOCATION = 8
/** Quante serie chiedere al database in un giro. */
const SELECTION_LIMIT = 400

serve(async (req: Request) => {
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405)

  // Fallisce chiuso: è un lavoro che spende budget condiviso senza che nessuno l'abbia chiesto.
  //
  // Il confronto va fatto con `cronAuth` e non con la sola `SERVICE_KEY` risolta qui sotto: la
  // chiave che il cron manda è quella del Vault (`edge_service_key`, la nuova `sb_secret_`),
  // mentre `SUPABASE_SERVICE_ROLE_KEY` nell'ambiente della funzione può essere ancora il JWT
  // legacy. Sono due valori diversi, quindi `authHeader !== 'Bearer ' + SERVICE_KEY` rispondeva
  // 401 **al cron vero** — verificato invocando la funzione esattamente come fa lo scheduler.
  // È la stessa trappola documentata in `cronAuth.ts`, che accetta l'intero insieme di chiavi
  // che identificano legittimamente il progetto.
  //
  // `SERVICE_KEY` resta, ma solo per la chiamata in USCITA a `catalog-resolve`, che si aspetta
  // proprio la chiave d'ambiente.
  const nonAutorizzato = rejectIfNotServiceCaller(req)
  if (nonAutorizzato) return nonAutorizzato

  const admin = adminClient()

  try {
    const { data: selezione, error: readError } = await admin
      .rpc('catalog_shows_needing_refresh', { p_limit: SELECTION_LIMIT })

    if (readError) throw new Error(`selezione fallita: ${readError.message}`)

    const showIds = [
      ...new Set(
        (selezione ?? [])
          .map((r: { tmdb_show_id: number }) => Number(r.tmdb_show_id))
          .filter((n: number) => Number.isFinite(n) && n > 0),
      ),
    ]

    if (showIds.length === 0) {
      return jsonResponse({ selected: 0, batches_sent: 0, budget_exhausted: false }, 200)
    }

    let batchesSent = 0
    let budgetEsaurito = false

    for (let i = 0; i < showIds.length && batchesSent < BATCHES_PER_INVOCATION; i += BATCH) {
      const lotto = showIds.slice(i, i + BATCH)

      const risposta = await fetch(`${SUPABASE_URL}/functions/v1/catalog-resolve`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          // **Le due intestazioni devono portare la STESSA chiave.** Con la chiave pubblicabile su
          // `apikey` e quella di servizio su `Authorization`, il gateway risponde 401 "Conflicting
          // API keys" e non arriva mai a `catalog-resolve` — verificato in produzione. La chiave
          // di servizio serve su `Authorization` perché è lì che `catalog-resolve` riconosce il
          // ramo "senza utente"; quindi va messa anche su `apikey`.
          'Authorization': `Bearer ${SERVICE_KEY}`,
          'apikey': SERVICE_KEY,
        },
        // `force_refresh`: senza, il filtro interno di `catalog-resolve` riscarterebbe proprio le
        // serie che stiamo cercando di rinfrescare (quelle "ended" col TTL ancora aperto).
        body: JSON.stringify({ show_ids: lotto, force_refresh: true }),
      })

      if (!risposta.ok) {
        const detail = (await risposta.text()).slice(0, 300)
        throw new Error(`catalog-resolve ha risposto ${risposta.status}: ${detail}`)
      }

      batchesSent++
      const esito = await risposta.json()
      if (esito?.budget_exhausted) {
        // Il tetto del rinfresco è fatto per essere raggiunto: si smette e si riprende domani.
        budgetEsaurito = true
        break
      }
    }

    return jsonResponse({
      selected: showIds.length,
      batches_sent: batchesSent,
      budget_exhausted: budgetEsaurito,
    }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error(`[catalog-refresh] ${message}`)
    return jsonResponse({ error: 'refresh_failed', detail: message }, 500)
  }
})
