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
import { isServiceCaller } from '../_shared/cronAuth.ts'
import {
  manualContextForPending,
  manualContextsFromCheckpoint,
  manualEpisodeDisposition,
  planEpisodeResolutionBatch,
} from './manual.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

/** La chiave con cui il driver del cron viene riconosciuto e con cui, quando è lui a guidare,
 *  si parla a `catalog-resolve`. Stessa risoluzione di `proxy.ts`. */
const SERVICE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()

/** §7.2: l'import risolve in batch da 50 — è anche il massimo che `catalog-resolve` accetta. */
const BATCH = 50
/** La chiave TMDB del progetto (la stessa di catalog-resolve): serve SOLO al fallback della
 *  risoluzione manuale, per validare i numeri dell'export contro la struttura stagioni. */
const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY') ?? ''
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
/** Giri CONSECUTIVI con `catalog-resolve` in errore prima di dichiarare il job `failed`.
 *  Col backoff del driver è UNA sonda al minuto: 30 coprono un throttle di TMDB, che al primo
 *  import vero è durato ~30 minuti — 5 lo dichiaravano guasto a un sesto della sua durata. */
const MAX_ERRORI_CONSECUTIVI = 30

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

  // Utente → RLS decide (chiusura dell'IDOR); driver del cron → service key, che nessun
  // client possiede. Stessa coppia di strade di `import-parse`.
  const daServizio = isServiceCaller(req)
  const lookup = daServizio ? admin : callerClient(req)

  const { data: job, error: jobError } = await lookup
    .from('import_jobs')
    .select('id, phase, status, totals, checkpoint')
    .eq('id', jobId)
    .maybeSingle()

  if (jobError) return jsonResponse({ error: 'job_lookup_failed', detail: jobError.message }, 401)
  if (!job) return jsonResponse({ error: 'job_not_found' }, 404)
  if (job.phase !== 'resolving') return jsonResponse({ error: 'wrong_phase', phase: job.phase }, 409)

  try {
    // Gli eventi prima, poi gli stati per-serie (§7.1) — vedi `risolviStati`. I voti invece si
    // agganciano per tvdb_episode_id nella fase di scrittura, quindi restano `pending` fin lì.
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
      // Eventi finiti: restano gli stati per-serie, che del catalogo hanno bisogno anche loro —
      // la riga di `tv_show_state` si scrive per `tmdb_show_id`, e una serie della watchlist può
      // non avere NESSUN episodio risolto da cui copiarlo (è il caso che dà valore alla strada:
      // le "seguite mai iniziate"). Si risolve per `tvdb_id` di serie, stesse regole degli
      // episodi: mai dedurre dai numeri, l'esito viene dalla mappa globale.
      return await risolviStati(req, admin, job, jobId, daServizio)
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

    // Un solo job può portare più scelte manuali. Ogni giro prende il contesto della prima
    // serie ancora presente nello staging; finita quella, lo stesso import prosegue sulla successiva.
    const manualContexts = manualContextsFromCheckpoint(job.checkpoint, jobId)
    const manualContext = manualContextForPending(manualContexts, pending)
    const piano = planEpisodeResolutionBatch(pending, noti, manualContext, BATCH)
    const mancanti = manualContext
      ? [...piano.requestedEpisodeIds, ...piano.deferredEpisodeIds]
      : episodeIds.filter((id) => !noti.has(id))
    const lotto = piano.requestedEpisodeIds
    const manualiRichiesti = new Set<number>()
    const manualiCompletati = new Set<number>()
    let budgetEsaurito = false

    // Un batch per invocazione: `catalog-resolve` ha il suo budget e la sua scadenza interna, e
    // sfondarli da qui significherebbe farsi rifiutare il resto del lavoro.
    let richiesti = 0
    if (lotto.length > 0) {
      richiesti = lotto.length
      if (manualContext) for (const id of lotto) manualiRichiesti.add(id)

      const risposta = await fetch(`${SUPABASE_URL}/functions/v1/catalog-resolve`, {
        method: 'POST',
        // Due chiamanti, due coppie di header — e le coppie NON si mescolano. Per un utente si
        // inoltra il suo JWT con l'apikey pubblica: il budget è suo. Per il driver del cron la
        // chiave service va su ENTRAMBI gli header: inoltrarla come Authorization accanto
        // all'apikey anon fa rispondere al gateway 401 "Conflicting API keys" — trovato dal
        // primo import vero, perché nel collaudo gli episodi erano già tutti in mappa e questa
        // chiamata non partiva mai. `catalog-resolve` col service key + job_id intesta comunque
        // il budget al proprietario del job (`importJobOwner`).
        headers: daServizio
          ? {
              'Content-Type': 'application/json',
              'Authorization': `Bearer ${SERVICE_KEY}`,
              'apikey': SERVICE_KEY,
            }
          : {
              'Content-Type': 'application/json',
              'Authorization': req.headers.get('Authorization') ?? '',
              'apikey': SUPABASE_ANON_KEY,
            },
        body: JSON.stringify({
          entities: lotto.map((id) => ({ tvdb_id: id, entity_type: 'episode' })),
          // Sblocca il budget da import: `catalog-resolve` verifica da sé che il job sia di chi
          // chiama e in fase `resolving`, quindi passarlo non è una dichiarazione ma una prova.
          job_id: jobId,
          ...(manualContext
            ? {
              show_ids: [manualContext.tmdb_show_id],
              manual_episode_context: manualContext,
            }
            : {}),
        }),
      })

      if (!risposta.ok) {
        // Un errore del fornitore a valle non è un verdetto sul job. Il primo import vero lo
        // ha dimostrato: dopo ~400 chiamate buone, UN 500 transitorio marcava `failed` un
        // import da 21.000 righe e chiedeva un dito umano su Riprova — il contrario di §7.2.
        // Il job resta `running` e il prossimo giro del driver riprova dallo stesso punto
        // (l'annotazione è idempotente); il contatore dei fallimenti CONSECUTIVI vive nel
        // checkpoint e si azzera al primo giro buono. Solo un guasto persistente diventa
        // `failed`, con l'ultimo errore in chiaro.
        const detail = (await risposta.text()).slice(0, 300)
        const errori = ((job.checkpoint as { resolve_errors?: number } | null)
          ?.resolve_errors ?? 0) + 1
        if (errori >= MAX_ERRORI_CONSECUTIVI) {
          throw new Error(
            `catalog-resolve ha risposto ${risposta.status} per ${errori} giri di fila: ${detail}`)
        }
        const checkpoint = job.checkpoint && typeof job.checkpoint === 'object'
          && !Array.isArray(job.checkpoint)
          ? { ...(job.checkpoint as Record<string, unknown>), resolve_errors: errori }
          : { resolve_errors: errori }
        const { error } = await admin.from('import_jobs')
          .update({ checkpoint }).eq('id', jobId)
        if (error) throw new Error(`contatore errori non salvato: ${error.message}`)
        // `retry: true` dice al driver di lasciar respirare QUESTO job fino al prossimo tick,
        // invece di martellare un servizio che sta già rispondendo male.
        return jsonResponse({
          done: false, phase: 'resolving', retry: true,
          errori_consecutivi: errori, detail,
        }, 200)
      }

      // Giro buono: un eventuale contatore di errori si azzera — conta la consecutività.
      if ((job.checkpoint as { resolve_errors?: number } | null)?.resolve_errors) {
        const checkpoint = { ...(job.checkpoint as Record<string, unknown>) }
        delete checkpoint.resolve_errors
        await admin.from('import_jobs').update({ checkpoint }).eq('id', jobId)
      }

      const esito = await risposta.json()
      budgetEsaurito = esito?.budget_exhausted ?? false

      if (manualContext) {
        const rimasti = new Set<number>(
          ((esito?.remaining ?? []) as { tvdb_id?: unknown }[])
            .map((entity) => Number(entity.tvdb_id))
            .filter((id) => Number.isSafeInteger(id) && id > 0),
        )
        for (const id of lotto) if (!rimasti.has(id)) manualiCompletati.add(id)

        // Nel percorso manuale le mappe non finali esistevano gia': si rilegge subito il lotto,
        // altrimenti il giro successivo le forzerebbe di nuovo senza mai annotare lo staging.
        const { data, error } = await admin
          .from('tvdb_tmdb_map')
          .select('tvdb_id, entity_type, tmdb_show_id, tmdb_movie_id, season_number, episode_number, resolution')
          .eq('entity_type', 'episode')
          .in('tvdb_id', lotto)
        if (error) throw new Error(`rilettura mappa manuale fallita: ${error.message}`)
        for (const row of (data ?? []) as MapRow[]) noti.set(row.tvdb_id, row)
      }

      // Non si annota nulla in questo giro per gli id appena chiesti: si torna, si rilegge la
      // mappa e li si trova. Un giro in più costa una query, dedurre l'esito dalla risposta
      // costerebbe una seconda interpretazione delle stesse regole.
      //
      // **Tranne a budget esaurito.** Prima si tornava sempre qui, quindi finché *un* id del
      // blocco mancava non veniva annotata *nessuna* riga: con 994 mancanti e il vecchio tetto
      // orario passavano due ore prima che una sola riga avanzasse, e nel frattempo ogni
      // invocazione rispondeva `done: false` senza aver fatto progressi. Se non si può più
      // chiedere, si annota almeno ciò che è già risolvibile — altrimenti il job si impianta.
      if (!manualContext && !budgetEsaurito) {
        return jsonResponse({
          done: false,
          phase: 'resolving',
          richiesti,
          ancora_da_risolvere: Math.max(0, mancanti.length - richiesti),
          budget_exhausted: false,
        }, 200)
      }

      if (!manualContext && noti.size === 0) {
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

    // Redesign 2.0, il fallback della serie CONFERMATA A MANO. TMDB `/find` non indicizza
    // tutti gli id episodio TVDB: per molte serie la mappa serie è `found` ma OGNI episodio
    // torna not_found — e il retry manuale sarebbe un giro a vuoto: l'utente sceglie la serie,
    // l'import gira, il titolo torna nell'inbox identico (la "risoluzione fittizia" vista al
    // primo collaudo). §6 vieta i numeri dell'export come identità DEDOTTA; qui però la serie
    // è una dichiarazione esplicita dell'utente, e i numeri si accettano solo se esistono
    // nella struttura stagioni TMDB di quella serie. L'esito finisce SOLO nello staging del
    // job — mai nella mappa globale, che resta catalogo puro.
    const stagioniManuali = manualContext
      ? await stagioniDellaSerieManuale(manualContext.tmdb_show_id)
      : null

    // Si annota ciò che la mappa sa: tutto il blocco nel caso normale, la sola parte già
    // risolvibile quando si arriva qui col budget esaurito.
    let risolte = 0
    let irrisolte = 0
    let fuoriStrutturaRighe = 0

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
      const episodeId = Number(raw.tvdb_episode_id)
      if (manualContext && Number(raw.tvdb_series_id) !== manualContext.tvdb_series_id) {
        continue
      }
      const mappa = noti.get(episodeId)
      // Con il budget esaurito si arriva qui con parte del blocco ancora fuori mappa: quelle
      // righe restano `pending` e le riprende il giro dopo, invece di essere marcate irrisolte.
      if (!mappa) continue

      const disposizioneManuale = manualContext
        ? manualEpisodeDisposition(
          mappa,
          manualContext.tmdb_show_id,
          manualiRichiesti.has(episodeId) && manualiCompletati.has(episodeId),
        )
        : null
      // Le mappe non finali delle tranche successive devono restare pending: annotarle ora
      // riuserebbe la vecchia risposta `not_found/ambiguous` e non verrebbero più ritentate.
      if (disposizioneManuale === 'pending') continue

      const conflittoSerie = disposizioneManuale === 'conflict'
      const trovato = manualContext
        ? disposizioneManuale === 'resolved'
        : mappa.resolution === 'found' && mappa.tmdb_show_id !== null

      // Nel caso normale i numeri vengono da TMDB, mai da quelli dell'export (§6). Il ramo
      // manuale, quando il catalogo ha detto not_found, prova i numeri DICHIARATI: validi solo
      // se la stagione esiste su TMDB e l'episodio sta dentro il suo conteggio.
      let resolvedRow: Record<string, unknown> | null = trovato
        ? {
          tmdb_show_id: mappa.tmdb_show_id,
          season_number: mappa.season_number,
          episode_number: mappa.episode_number,
        }
        : null
      let esitoRisolto = trovato
      let fuoriStruttura = false
      let erroreRiga = trovato
        ? null
        : (conflittoSerie ? 'catalogo: conflitto_serie' : `catalogo: ${mappa.resolution ?? 'assente'}`)

      if (!trovato && manualContext && disposizioneManuale === 'unresolved' && stagioniManuali) {
        const stagione = Number(raw.season_number)
        const numero = Number(raw.episode_number)
        if (Number.isSafeInteger(stagione) && stagione >= 0 &&
          Number.isSafeInteger(numero) && numero >= 1 &&
          (stagioniManuali.get(stagione) ?? 0) >= numero) {
          resolvedRow = {
            tmdb_show_id: manualContext.tmdb_show_id,
            season_number: stagione,
            episode_number: numero,
            // Tracciabilità: questa identità viene dai numeri dell'export confermati
            // dall'utente, non dalla mappa globale. La fase 4 legge solo i tre campi sopra.
            via: 'numeri_export',
          }
          esitoRisolto = true
          erroreRiga = null
        } else {
          // La serie è CONFERMATA e la struttura TMDB è QUI: se i numeri dell'export non
          // ci stanno (episodio 0 = "TV Time non sa più il numero", stagioni che TMDB non
          // ha, speciali assenti), nessun retry potrà mai collocarli. Lasciarli
          // `unresolved` teneva la card nell'inbox per sempre, con l'utente che riprovava
          // a vuoto — visto al primo import vero: 692 episodi su 36 serie, tutti così.
          // Diventano una decisione terminale, dichiarata nel report (§7.4: la perdita
          // si dice, non si nasconde). Solo con la struttura in mano: un fetch TMDB
          // fallito NON è un verdetto e lascia la riga retriabile.
          resolvedRow = null
          erroreRiga = 'manuale: fuori_struttura_tmdb'
          fuoriStruttura = true
        }
      }

      daScrivere.push({
        job_id: jobId,
        row_index: riga.row_index,
        raw,
        resolved: resolvedRow,
        // `skipped` per il fuori-struttura: è una decisione, non un lavoro rimasto a metà —
        // e non deve riaprirsi al prossimo giro di risoluzione manuale.
        status: esitoRisolto ? 'resolved' : (fuoriStruttura ? 'skipped' : 'unresolved'),
        error: erroreRiga,
      })
      esitoRisolto ? risolte++ : irrisolte++
      if (fuoriStruttura) fuoriStrutturaRighe++
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
      // Quanti dei non risolti sono decisioni TERMINALI del ramo manuale (numeri dell'export
      // fuori dalla struttura TMDB della serie confermata): il report li dichiara a parte.
      fuori_struttura:
        ((job.totals as Record<string, number>)?.fuori_struttura ?? 0) + fuoriStrutturaRighe,
    }

    const { error: updateError } = await admin.from('import_jobs')
      .update({ totals }).eq('id', jobId)
    if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

    return jsonResponse({
      done: false,
      phase: 'resolving',
      risolte,
      irrisolte,
      ancora_da_risolvere: piano.deferredEpisodeIds.length,
      budget_exhausted: budgetEsaurito,
      totals,
    }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    await admin.from('import_jobs')
      .update({ status: 'failed', error: message.slice(0, 500) }).eq('id', jobId)
    return jsonResponse({ error: 'resolve_failed', detail: message }, 500)
  }
})

/**
 * La struttura stagioni della serie confermata a mano: stagione → numero di episodi.
 * Una chiamata TMDB per invocazione (solo nel ramo manuale), e un esito nullo — chiave
 * assente, serie sconosciuta, TMDB giù — spegne il fallback per questo giro invece di
 * rischiare episodi inventati: le righe restano `unresolved`, un retry successivo riprova.
 */
async function stagioniDellaSerieManuale(
  tmdbShowId: number,
): Promise<Map<number, number> | null> {
  if (TMDB_API_KEY === '') return null
  try {
    const risposta = await fetch(
      `https://api.themoviedb.org/3/tv/${tmdbShowId}?api_key=${TMDB_API_KEY}`,
    )
    if (!risposta.ok) return null
    const corpo = await risposta.json() as { seasons?: unknown[] }
    const mappa = new Map<number, number>()
    for (const stagione of corpo?.seasons ?? []) {
      const s = stagione as Record<string, unknown>
      const numero = Number(s?.season_number)
      const episodi = Number(s?.episode_count)
      if (Number.isSafeInteger(numero) && numero >= 0 &&
        Number.isSafeInteger(episodi) && episodi > 0) {
        mappa.set(numero, episodi)
      }
    }
    return mappa.size > 0 ? mappa : null
  } catch {
    return null
  }
}

/**
 * La coda della fase 3: le righe per-SERIE — stati (§7.1) e candidati favorites (§7.1),
 * risolte insieme: stessa entità, stessa mappa, stesso giro. I contatori nei totals restano
 * separati per kind, così il report non somma pere con mele.
 *
 * Stessa architettura del giro sugli eventi — mappa prima, `catalog-resolve` solo per ciò che
 * manca, annotazione in blocco, contatore di errori CONSECUTIVI nel checkpoint — perché sono gli
 * stessi rischi: budget, transitori del fornitore, PostgREST che tronca. Un errore qui propaga al
 * `catch` del chiamante, che marca il job come farebbe per gli eventi.
 */
async function risolviStati(
  req: Request,
  admin: ReturnType<typeof adminClient>,
  job: { checkpoint: unknown; totals: unknown },
  jobId: string,
  daServizio: boolean,
): Promise<Response> {
  const { data: pending, error: pendingError } = await admin
    .from('import_staging')
    .select('row_index, raw')
    .eq('job_id', jobId)
    .eq('status', 'pending')
    .in('raw->>row_kind', ['status', 'favorite'])
    .order('row_index', { ascending: true })
    .limit(ROWS_PER_INVOCATION)

  if (pendingError) throw new Error(`lettura stati fallita: ${pendingError.message}`)

  if (!pending || pending.length === 0) {
    // Stati e favorites finiti: restano i film (§7.1), che non passano dalla mappa TVDB —
    // non hanno NESSUN id esterno, si risolvono per titolo (exact-match+anno o niente).
    return await risolviFilm(req, admin, job, jobId, daServizio)
  }

  const seriesIds = [
    ...new Set(
      pending
        .map((r) => Number((r.raw as Record<string, unknown>).tvdb_series_id))
        .filter((n) => Number.isFinite(n) && n > 0),
    ),
  ]

  const noti = new Map<number, MapRow>()
  for (let i = 0; i < seriesIds.length; i += 500) {
    const { data, error } = await admin
      .from('tvdb_tmdb_map')
      .select('tvdb_id, entity_type, tmdb_show_id, tmdb_movie_id, season_number, episode_number, resolution')
      .eq('entity_type', 'series')
      .in('tvdb_id', seriesIds.slice(i, i + 500))
    if (error) throw new Error(`lettura mappa fallita: ${error.message}`)
    for (const row of (data ?? []) as MapRow[]) noti.set(row.tvdb_id, row)
  }

  const mancanti = seriesIds.filter((id) => !noti.has(id))

  let richiesti = 0
  let budgetEsaurito = false
  if (mancanti.length > 0) {
    const lotto = mancanti.slice(0, BATCH)
    richiesti = lotto.length

    const risposta = await fetch(`${SUPABASE_URL}/functions/v1/catalog-resolve`, {
      method: 'POST',
      // Stesse coppie di header del giro sugli eventi, e per la stessa ragione: mescolarle è il
      // 401 "Conflicting API keys" trovato dal primo import vero.
      headers: daServizio
        ? {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${SERVICE_KEY}`,
            'apikey': SERVICE_KEY,
          }
        : {
            'Content-Type': 'application/json',
            'Authorization': req.headers.get('Authorization') ?? '',
            'apikey': SUPABASE_ANON_KEY,
          },
      body: JSON.stringify({
        entities: lotto.map((id) => ({ tvdb_id: id, entity_type: 'series' })),
        job_id: jobId,
      }),
    })

    if (!risposta.ok) {
      // Stesso contratto degli eventi: un transitorio del fornitore non è un verdetto sul job.
      const detail = (await risposta.text()).slice(0, 300)
      const errori = ((job.checkpoint as { resolve_errors?: number } | null)
        ?.resolve_errors ?? 0) + 1
      if (errori >= MAX_ERRORI_CONSECUTIVI) {
        throw new Error(
          `catalog-resolve (serie) ha risposto ${risposta.status} per ${errori} giri di fila: ${detail}`)
      }
      const { error } = await admin.from('import_jobs')
        .update({ checkpoint: { resolve_errors: errori } }).eq('id', jobId)
      if (error) throw new Error(`contatore errori non salvato: ${error.message}`)
      return jsonResponse({
        done: false, phase: 'resolving', retry: true,
        errori_consecutivi: errori, detail,
      }, 200)
    }

    if ((job.checkpoint as { resolve_errors?: number } | null)?.resolve_errors) {
      await admin.from('import_jobs').update({ checkpoint: {} }).eq('id', jobId)
    }

    const esito = await risposta.json()
    budgetEsaurito = esito?.budget_exhausted ?? false

    // Come per gli eventi: gli id appena chiesti si annotano al giro dopo rileggendo la mappa,
    // tranne a budget esaurito, dove si annota almeno ciò che è già risolvibile.
    if (!budgetEsaurito) {
      return jsonResponse({
        done: false,
        phase: 'resolving',
        stati: true,
        richiesti,
        ancora_da_risolvere: Math.max(0, mancanti.length - richiesti),
        budget_exhausted: false,
      }, 200)
    }
  }

  let risolte = 0
  let irrisolte = 0
  let favRisolte = 0
  let favIrrisolte = 0
  const daScrivere = []
  for (const riga of pending) {
    const raw = riga.raw as Record<string, unknown>
    const daFavorite = raw.row_kind === 'favorite'
    const id = Number(raw.tvdb_series_id)

    // Un id non numerico non arriverà mai in mappa: si dichiara irrisolto SUBITO, altrimenti la
    // riga resterebbe `pending` per sempre e la fase non avanzerebbe più.
    if (!Number.isFinite(id) || id <= 0) {
      daScrivere.push({
        job_id: jobId,
        row_index: riga.row_index,
        raw,
        resolved: null,
        status: 'unresolved',
        error: 'id serie mancante nell\'export',
      })
      daFavorite ? favIrrisolte++ : irrisolte++
      continue
    }

    const mappa = noti.get(id)
    if (!mappa) continue // fuori mappa (budget esaurito): riprende il giro dopo
    const trovato = mappa.resolution === 'found' && mappa.tmdb_show_id !== null

    daScrivere.push({
      job_id: jobId,
      row_index: riga.row_index,
      raw,
      resolved: trovato ? { tmdb_show_id: mappa.tmdb_show_id } : null,
      status: trovato ? 'resolved' : 'unresolved',
      error: trovato ? null : `catalogo: ${mappa.resolution ?? 'assente'}`,
    })
    if (daFavorite) { trovato ? favRisolte++ : favIrrisolte++ }
    else { trovato ? risolte++ : irrisolte++ }
  }

  for (let i = 0; i < daScrivere.length; i += ROWS_PER_UPSERT) {
    const { error } = await admin
      .from('import_staging')
      .upsert(daScrivere.slice(i, i + ROWS_PER_UPSERT), { onConflict: 'job_id,row_index' })
    if (error) throw new Error(`annotazione stati fallita dal blocco ${i}: ${error.message}`)
  }

  const totals = {
    ...(job.totals as Record<string, unknown> ?? {}),
    statuses_resolved: ((job.totals as Record<string, number>)?.statuses_resolved ?? 0) + risolte,
    statuses_unresolved:
      ((job.totals as Record<string, number>)?.statuses_unresolved ?? 0) + irrisolte,
    favorites_resolved:
      ((job.totals as Record<string, number>)?.favorites_resolved ?? 0) + favRisolte,
    favorites_unresolved:
      ((job.totals as Record<string, number>)?.favorites_unresolved ?? 0) + favIrrisolte,
  }

  const { error: updateError } = await admin.from('import_jobs')
    .update({ totals }).eq('id', jobId)
  if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

  return jsonResponse({
    done: false,
    phase: 'resolving',
    stati: true,
    risolte,
    irrisolte,
    budget_exhausted: mancanti.length > 0,
    totals,
  }, 200)
}

/**
 * La terza coda della fase 3: i FILM di v1 (§7.1). Nessuna mappa TVDB di mezzo — un film
 * dell'export non ha id esterni, solo l'uuid interno di TV Time e un nome — quindi si chiede a
 * `catalog-resolve` la risoluzione per titolo (`movie_titles`, exact-match+anno o niente) e si
 * annota direttamente dalla risposta: non c'è una cache condivisa da rileggere al giro dopo, e
 * un re-import ripaga le sue ~8 chiamate di ricerca invece di guadagnarsi una tabella nuova.
 *
 * Le righe dello stesso film (le rivisioni) condividono l'uuid e quindi l'esito: si chiede una
 * volta per uuid, si annota ogni riga. `movie_remaining` (budget/upstream) resta `pending` e
 * riprende al giro dopo — stesso contratto delle altre code.
 */
async function risolviFilm(
  req: Request,
  admin: ReturnType<typeof adminClient>,
  job: { checkpoint: unknown; totals: unknown },
  jobId: string,
  daServizio: boolean,
): Promise<Response> {
  const { data: pending, error: pendingError } = await admin
    .from('import_staging')
    .select('row_index, raw')
    .eq('job_id', jobId)
    .eq('status', 'pending')
    .eq('raw->>row_kind', 'movie')
    .order('row_index', { ascending: true })
    .limit(ROWS_PER_INVOCATION)

  if (pendingError) throw new Error(`lettura film fallita: ${pendingError.message}`)

  if (!pending || pending.length === 0) {
    const { error } = await admin.from('import_jobs')
      .update({ phase: 'writing', checkpoint: {} }).eq('id', jobId)
    if (error) throw new Error(`avanzamento non salvato: ${error.message}`)
    return jsonResponse({ done: true, phase: 'writing', annotated: 0 }, 200)
  }

  // Una richiesta per uuid, non per riga: le rivisioni condividono il film.
  const richieste = new Map<string, { title: string; year: number | null }>()
  for (const riga of pending) {
    const raw = riga.raw as Record<string, unknown>
    const uuid = String(raw.tvtime_movie_uuid ?? '')
    const title = String(raw.title ?? '')
    if (uuid === '' || title === '') continue
    if (!richieste.has(uuid)) {
      const year = Number(raw.release_year)
      richieste.set(uuid, {
        title,
        year: Number.isSafeInteger(year) && year > 0 ? year : null,
      })
    }
  }

  const esiti = new Map<string, {
    outcome: string
    tmdb_movie_id: number | null
    matched_title?: string | null
    poster_path?: string | null
  }>()
  if (richieste.size > 0) {
    const lotto = [...richieste.entries()].slice(0, BATCH)

    const risposta = await fetch(`${SUPABASE_URL}/functions/v1/catalog-resolve`, {
      method: 'POST',
      // Stesse coppie di header delle altre code, stessa ragione (401 "Conflicting API keys").
      headers: daServizio
        ? {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${SERVICE_KEY}`,
            'apikey': SERVICE_KEY,
          }
        : {
            'Content-Type': 'application/json',
            'Authorization': req.headers.get('Authorization') ?? '',
            'apikey': SUPABASE_ANON_KEY,
          },
      body: JSON.stringify({
        movie_titles: lotto.map(([key, r]) => ({ key, title: r.title, year: r.year })),
        job_id: jobId,
      }),
    })

    if (!risposta.ok) {
      // Stesso contratto delle altre code: un transitorio del fornitore non è un verdetto.
      const detail = (await risposta.text()).slice(0, 300)
      const errori = ((job.checkpoint as { resolve_errors?: number } | null)
        ?.resolve_errors ?? 0) + 1
      if (errori >= MAX_ERRORI_CONSECUTIVI) {
        throw new Error(
          `catalog-resolve (film) ha risposto ${risposta.status} per ${errori} giri di fila: ${detail}`)
      }
      const { error } = await admin.from('import_jobs')
        .update({ checkpoint: { resolve_errors: errori } }).eq('id', jobId)
      if (error) throw new Error(`contatore errori non salvato: ${error.message}`)
      return jsonResponse({
        done: false, phase: 'resolving', retry: true,
        errori_consecutivi: errori, detail,
      }, 200)
    }

    if ((job.checkpoint as { resolve_errors?: number } | null)?.resolve_errors) {
      await admin.from('import_jobs').update({ checkpoint: {} }).eq('id', jobId)
    }

    const corpo = await risposta.json()
    for (const match of (corpo?.movie_matches ?? []) as
      { key: string; outcome: string; tmdb_movie_id: number | null;
        matched_title?: string | null; poster_path?: string | null }[]) {
      esiti.set(match.key, match)
    }
  }

  let risolte = 0
  let irrisolte = 0
  const daScrivere = []
  for (const riga of pending) {
    const raw = riga.raw as Record<string, unknown>
    const uuid = String(raw.tvtime_movie_uuid ?? '')
    const title = String(raw.title ?? '')

    // Senza uuid o titolo non c'è niente da chiedere: si dichiara subito, o la riga resterebbe
    // `pending` per sempre e la fase non avanzerebbe più.
    if (uuid === '' || title === '') {
      daScrivere.push({
        job_id: jobId, row_index: riga.row_index, raw,
        resolved: null, status: 'unresolved', error: 'film: titolo o uuid mancante nell\'export',
      })
      irrisolte++
      continue
    }

    const esito = esiti.get(uuid)
    if (!esito) continue // movie_remaining (budget/upstream): riprende il giro dopo

    const trovato = esito.outcome === 'found' && esito.tmdb_movie_id !== null
    daScrivere.push({
      job_id: jobId,
      row_index: riga.row_index,
      raw,
      // titolo e poster di TMDB viaggiano con l'id: la fase 4 scrive la riga di lista legacy
      // e senza il poster la card resterebbe un rettangolo grigio.
      resolved: trovato
        ? {
            tmdb_movie_id: esito.tmdb_movie_id,
            matched_title: esito.matched_title ?? null,
            poster_path: esito.poster_path ?? null,
          }
        : null,
      status: trovato ? 'resolved' : 'unresolved',
      error: trovato ? null : `film: ${esito.outcome === 'no_year' ? 'anno mancante' : esito.outcome}`,
    })
    trovato ? risolte++ : irrisolte++
  }

  for (let i = 0; i < daScrivere.length; i += ROWS_PER_UPSERT) {
    const { error } = await admin
      .from('import_staging')
      .upsert(daScrivere.slice(i, i + ROWS_PER_UPSERT), { onConflict: 'job_id,row_index' })
    if (error) throw new Error(`annotazione film fallita dal blocco ${i}: ${error.message}`)
  }

  const totals = {
    ...(job.totals as Record<string, unknown> ?? {}),
    movies_resolved: ((job.totals as Record<string, number>)?.movies_resolved ?? 0) + risolte,
    movies_unresolved:
      ((job.totals as Record<string, number>)?.movies_unresolved ?? 0) + irrisolte,
  }

  const { error: updateError } = await admin.from('import_jobs')
    .update({ totals }).eq('id', jobId)
  if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

  return jsonResponse({
    done: false,
    phase: 'resolving',
    film: true,
    risolte,
    irrisolte,
    totals,
  }, 200)
}
