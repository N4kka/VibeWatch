// Riscaldamento della mappa TVDB→TMDB (SPEC v3 §1.5), invocato da `pg_cron`.
//
// **Perché esiste.** La mappa è condivisa: "il primo utente che importa una serie paga; tutti gli
// altri la trovano già risolta". Il primo però paga caro — un export reale è 21.189 episodi, e §6
// vuole una `/find` per `tvdb_episode_id` perché dedurre la corrispondenza dai numeri è il modo
// documentato di sbagliare. Questa funzione sposta quel costo dove non lo aspetta nessuno: di
// notte, sulla coda che gli import hanno lasciato indietro.
//
// **Cosa risolve, in ordine.** Gli id che stanno in un `import_staging` ancora `pending` e non
// sono nella mappa: è la coda vera, non una lista di popolarità inventata. Un id che nessuno ha
// mai chiesto non serve a nessuno.
//
// Autenticazione: solo la chiave di servizio. Non c'è un utente dietro, e il budget ha uno scope
// suo (`prewarm`) con un tetto sotto quello da import — se il budget globale è conteso deve
// perdere il lavoro che nessuno sta aspettando.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
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

serve(async (req: Request) => {
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405)

  const authHeader = req.headers.get('authorization') ?? req.headers.get('Authorization') ?? ''
  if (SERVICE_KEY === '' || authHeader !== `Bearer ${SERVICE_KEY}`) {
    // Fallisce chiuso: senza la chiave di servizio non si riscalda niente. È un lavoro che spende
    // budget condiviso senza che nessuno l'abbia chiesto, quindi la porta sta chiusa di default.
    return jsonResponse({ error: 'service_key_required' }, 401)
  }

  const admin = adminClient()

  try {
    // La coda: id che un import sta ancora aspettando e che la mappa non conosce. Il `limit` è
    // sotto le 1000 righe che PostgREST restituisce comunque — chiedere di più darebbe un numero
    // che non corrisponde a ciò che si riceve, ed è il difetto già trovato in `import-resolve`.
    const { data: attesa, error: readError } = await admin
      .from('import_staging')
      .select('raw')
      .eq('status', 'pending')
      .eq('raw->>row_kind', 'event')
      .limit(1000)

    if (readError) throw new Error(`lettura della coda fallita: ${readError.message}`)

    const candidati = [
      ...new Set(
        (attesa ?? [])
          .map((r) => Number((r.raw as Record<string, unknown>).tvdb_episode_id))
          .filter((n) => Number.isFinite(n) && n > 0),
      ),
    ]

    if (candidati.length === 0) {
      return jsonResponse({ done: true, coda: 0, risolti: 0 }, 200)
    }

    // Cosa la mappa sa già: chiedere di nuovo costerebbe una chiamata TMDB per niente.
    const noti = new Set<number>()
    for (let i = 0; i < candidati.length; i += 500) {
      const { data, error } = await admin
        .from('tvdb_tmdb_map')
        .select('tvdb_id')
        .eq('entity_type', 'episode')
        .in('tvdb_id', candidati.slice(i, i + 500))
      if (error) throw new Error(`lettura mappa fallita: ${error.message}`)
      for (const row of data ?? []) noti.add(row.tvdb_id as number)
    }

    const mancanti = candidati.filter((id) => !noti.has(id))
    let richiesti = 0
    let budgetEsaurito = false

    for (let i = 0; i < mancanti.length && i < BATCH * BATCHES_PER_INVOCATION; i += BATCH) {
      const lotto = mancanti.slice(i, i + BATCH)

      const risposta = await fetch(`${SUPABASE_URL}/functions/v1/catalog-resolve`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          // La chiave di servizio è ciò che `catalog-resolve` riconosce come "riscaldamento".
          'Authorization': `Bearer ${SERVICE_KEY}`,
          'apikey': SUPABASE_ANON_KEY,
        },
        body: JSON.stringify({
          entities: lotto.map((id) => ({ tvdb_id: id, entity_type: 'episode' })),
        }),
      })

      if (!risposta.ok) {
        const detail = (await risposta.text()).slice(0, 300)
        throw new Error(`catalog-resolve ha risposto ${risposta.status}: ${detail}`)
      }

      richiesti += lotto.length
      const esito = await risposta.json()
      if (esito?.budget_exhausted) {
        // Il tetto del riscaldamento è fatto per essere raggiunto: si smette e si riprende domani.
        budgetEsaurito = true
        break
      }
    }

    return jsonResponse({
      done: mancanti.length <= richiesti,
      coda: mancanti.length,
      richiesti,
      budget_exhausted: budgetEsaurito,
    }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error(`[catalog-prewarm] ${message}`)
    return jsonResponse({ error: 'prewarm_failed', detail: message }, 500)
  }
})
