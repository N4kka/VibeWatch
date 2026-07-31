// Fase 3 dell'import TV Time (SPEC v3 §7.2): dagli id TVDB in staging agli id TMDB.
//
// Non risolve nulla da sé: delega a `catalog-resolve`, che è già in produzione, ha il suo budget e
// scrive `tvdb_tmdb_map` — una mappa **globale** (§1.5), quindi il primo utente che importa una
// serie paga la chiamata e tutti gli altri la trovano già fatta. Qui si fa solo il lavoro di
// cucitura: capire quali id mancano, chiederli a 50 per volta, e riportare l'esito sulle righe.
//
// Il principio di §6 vale anche qui: **non si deduce mai un episodio dai numeri di stagione e
// episodio**. TVDB e TMDB numerano diversamente — l'oracolo mostra 31 serie su 430 in disaccordo —
// quindi si risolve per `tvdb_id` e i numeri si prendono dalla risposta di TMDB.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

/** §7.2: l'import risolve in batch da 50 — è anche il massimo che `catalog-resolve` accetta. */
const BATCH = 50
/**
 * Righe di staging lette per invocazione.
 *
 * **1000 e non di più, perché PostgREST tronca lì.** Il limite non è sul ruolo — `pgrst.db_max_rows`
 * è nullo, ed è guardare quello che aveva portato a concludere che il tetto non esistesse — ma
 * nella configurazione PostgREST del progetto. Con `.limit(4000)` questa funzione ne riceveva 1000
 * e credeva di averne viste 4000: sull'export vero le prime 4.000 righe contengono 3.994 episodi
 * distinti e ne vedeva 994. Non perdeva dati, perché il ciclo continua, ma la costante mentiva.
 */
const ROWS_PER_INVOCATION = 1_000
/** Righe per singola scrittura: oltre, il payload inizia a pesare piu' del round-trip. */
const ROWS_PER_UPSERT = 500

/**
 * Legge il job **come il chiamante**: è la policy `import_jobs_select_own` a decidere se esiste.
 * Leggerlo da admin e confrontare `user_id` a mano è come è nato l'IDOR della fase 2.
 */
function callerClient(req: Request) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false },
  })
}

interface MapRow {
  tvdb_id: number
  entity_type: string
  tmdb_show_id: number | null
  tmdb_movie_id: number | null
  season_number: number | null
  episode_number: number | null
  resolution: string
}

serve(async (req: Request) => {
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405)

  let jobId: string
  try {
    jobId = (await req.json()).job_id
    if (typeof jobId !== 'string' || jobId.length === 0) throw new Error('job_id')
  } catch {
    return jsonResponse({ error: 'job_id_required' }, 400)
  }

  const admin = adminClient()

  const { data: job, error: jobError } = await callerClient(req)
    .from('import_jobs')
    .select('id, phase, status, totals')
    .eq('id', jobId)
    .maybeSingle()

  if (jobError) return jsonResponse({ error: 'job_lookup_failed', detail: jobError.message }, 401)
  if (!job) return jsonResponse({ error: 'job_not_found' }, 404)
  if (job.phase !== 'resolving') return jsonResponse({ error: 'wrong_phase', phase: job.phase }, 409)

  try {
    // Solo gli eventi hanno bisogno del catalogo. I voti si agganciano per tvdb_episode_id nella
    // fase di scrittura, quindi restano `pending` fin lì.
    const { data: pending, error: pendingError } = await admin
      .from('import_staging')
      .select('row_index, raw')
      .eq('job_id', jobId)
      .eq('status', 'pending')
      .eq('raw->>row_kind', 'event')
      .order('row_index', { ascending: true })
      .limit(ROWS_PER_INVOCATION)

    if (pendingError) throw new Error(`lettura staging fallita: ${pendingError.message}`)

    if (!pending || pending.length === 0) {
      const { error } = await admin.from('import_jobs')
        .update({ phase: 'writing', checkpoint: {} }).eq('id', jobId)
      if (error) throw new Error(`avanzamento non salvato: ${error.message}`)
      return jsonResponse({ done: true, phase: 'writing', annotated: 0 }, 200)
    }

    const episodeIds = [
      ...new Set(
        pending
          .map((r) => Number((r.raw as Record<string, unknown>).tvdb_episode_id))
          .filter((n) => Number.isFinite(n) && n > 0),
      ),
    ]

    // Cosa la mappa globale sa già. Chiedere a `catalog-resolve` ciò che è noto costerebbe una
    // chiamata TMDB per niente, e con 432 serie la differenza è tutta lì.
    const noti = new Map<number, MapRow>()
    for (let i = 0; i < episodeIds.length; i += 500) {
      const { data, error } = await admin
        .from('tvdb_tmdb_map')
        .select('tvdb_id, entity_type, tmdb_show_id, tmdb_movie_id, season_number, episode_number, resolution')
        .eq('entity_type', 'episode')
        .in('tvdb_id', episodeIds.slice(i, i + 500))
      if (error) throw new Error(`lettura mappa fallita: ${error.message}`)
      for (const row of (data ?? []) as MapRow[]) noti.set(row.tvdb_id, row)
    }

    const mancanti = episodeIds.filter((id) => !noti.has(id))

    // Un batch per invocazione: `catalog-resolve` ha il suo budget e la sua scadenza interna, e
    // sfondarli da qui significherebbe farsi rifiutare il resto del lavoro.
    let richiesti = 0
    if (mancanti.length > 0) {
      const lotto = mancanti.slice(0, BATCH)
      richiesti = lotto.length

      const risposta = await fetch(`${SUPABASE_URL}/functions/v1/catalog-resolve`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          // Si inoltra il JWT dell'utente: `catalog-resolve` vuole un token vero, non la chiave
          // di servizio, ed è giusto che il budget sia attribuito a chi sta importando.
          'Authorization': req.headers.get('Authorization') ?? '',
          'apikey': SUPABASE_ANON_KEY,
        },
        body: JSON.stringify({
          entities: lotto.map((id) => ({ tvdb_id: id, entity_type: 'episode' })),
          // Sblocca il budget da import: `catalog-resolve` verifica da sé che il job sia di chi
          // chiama e in fase `resolving`, quindi passarlo non è una dichiarazione ma una prova.
          job_id: jobId,
        }),
      })

      if (!risposta.ok) {
        const detail = (await risposta.text()).slice(0, 300)
        throw new Error(`catalog-resolve ha risposto ${risposta.status}: ${detail}`)
      }

      const esito = await risposta.json()
      const budgetEsaurito = esito?.budget_exhausted ?? false

      // Non si annota nulla in questo giro per gli id appena chiesti: si torna, si rilegge la
      // mappa e li si trova. Un giro in più costa una query, dedurre l'esito dalla risposta
      // costerebbe una seconda interpretazione delle stesse regole.
      //
      // **Tranne a budget esaurito.** Prima si tornava sempre qui, quindi finché *un* id del
      // blocco mancava non veniva annotata *nessuna* riga: con 994 mancanti e il vecchio tetto
      // orario passavano due ore prima che una sola riga avanzasse, e nel frattempo ogni
      // invocazione rispondeva `done: false` senza aver fatto progressi. Se non si può più
      // chiedere, si annota almeno ciò che è già risolvibile — altrimenti il job si impianta.
      if (!budgetEsaurito) {
        return jsonResponse({
          done: false,
          phase: 'resolving',
          richiesti,
          ancora_da_risolvere: Math.max(0, mancanti.length - richiesti),
          budget_exhausted: false,
        }, 200)
      }

      if (noti.size === 0) {
        // Nulla di annotabile e budget finito: dirlo, invece di girare a vuoto.
        return jsonResponse({
          done: false,
          phase: 'resolving',
          richiesti,
          ancora_da_risolvere: mancanti.length,
          budget_exhausted: true,
          annotate: 0,
        }, 200)
      }
    }

    // Si annota ciò che la mappa sa: tutto il blocco nel caso normale, la sola parte già
    // risolvibile quando si arriva qui col budget esaurito.
    let risolte = 0
    let irrisolte = 0

    // **Si scrive in blocco, non riga per riga.** Una UPDATE per riga sono ~47 ms di andata e
    // ritorno l'una: misurato, annotare 1000 righe costava **47 secondi**, cioe' piu' di tutte le
    // chiamate a TMDB dello stesso blocco messe insieme. Dopo aver parallelizzato le `/find` era
    // diventato il collo di bottiglia vero — il posto dove si perde tempo si sposta appena si
    // sistema il precedente, e l'unico modo di saperlo e' cronometrare invece di dedurre.
    //
    // L'upsert vuole la riga intera perche' `raw` e' NOT NULL: si rimanda indietro quella letta,
    // senza toccarla. La chiave (job_id, row_index) fa il resto.
    const daScrivere = []
    for (const riga of pending) {
      const raw = riga.raw as Record<string, unknown>
      const mappa = noti.get(Number(raw.tvdb_episode_id))
      // Con il budget esaurito si arriva qui con parte del blocco ancora fuori mappa: quelle
      // righe restano `pending` e le riprende il giro dopo, invece di essere marcate irrisolte.
      if (!mappa) continue
      const trovato = mappa.resolution === 'found' && mappa.tmdb_show_id !== null

      daScrivere.push({
        job_id: jobId,
        row_index: riga.row_index,
        raw,
        // I numeri vengono da TMDB, mai da quelli dell'export (§6).
        resolved: trovato
          ? {
            tmdb_show_id: mappa.tmdb_show_id,
            season_number: mappa.season_number,
            episode_number: mappa.episode_number,
          }
          : null,
        status: trovato ? 'resolved' : 'unresolved',
        error: trovato ? null : `catalogo: ${mappa.resolution ?? 'assente'}`,
      })
      trovato ? risolte++ : irrisolte++
    }

    for (let i = 0; i < daScrivere.length; i += ROWS_PER_UPSERT) {
      const { error } = await admin
        .from('import_staging')
        .upsert(daScrivere.slice(i, i + ROWS_PER_UPSERT), { onConflict: 'job_id,row_index' })
      if (error) throw new Error(`annotazione fallita dal blocco ${i}: ${error.message}`)
    }

    // I non riconosciuti sono materiale obbligatorio del report (§7.4): un import che perde 200
    // episodi in silenzio è peggio di uno che dichiara il problema.
    const totals = {
      ...(job.totals as Record<string, unknown> ?? {}),
      resolved: ((job.totals as Record<string, number>)?.resolved ?? 0) + risolte,
      unresolved: ((job.totals as Record<string, number>)?.unresolved ?? 0) + irrisolte,
    }

    const { error: updateError } = await admin.from('import_jobs')
      .update({ totals }).eq('id', jobId)
    if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

    return jsonResponse({
      done: false,
      phase: 'resolving',
      risolte,
      irrisolte,
      budget_exhausted: mancanti.length > 0,
      totals,
    }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    await admin.from('import_jobs')
      .update({ status: 'failed', error: message.slice(0, 500) }).eq('id', jobId)
    return jsonResponse({ error: 'resolve_failed', detail: message }, 500)
  }
})
