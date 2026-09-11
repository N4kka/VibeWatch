// SPEC v3 §7.2 — "L'utente può chiudere l'app: il job prosegue server-side. Chi lo fa
// proseguire è questa funzione, invocata dal cron ogni minuto.
//
// Il driver non sa niente delle fasi: le fa avanzare chiamando le funzioni che le conoscono
// (`import-parse`, `import-resolve`, `import-write`, `import-finalize`), ognuna col proprio
// checkpoint, finché il budget di tempo regge. Tre proprietà non ovvie:
//
//   * **Il lease (`locked_until`) è ciò che permette al cron di partire ogni minuto.** Un giro
//     può durare più di un minuto (una singola invocazione di `import-resolve` su un blocco
//     pieno sfora il minuto): senza claim atomico due driver farebbero avanzare lo stesso job
//     insieme — la stessa corsa per cui il client NON guida le fasi ma le guarda soltanto.
//     Se il driver muore, il lease scade da solo.
//   * **La verità sta nel DB, non nella risposta.** Dopo ogni chiamata di fase si rilegge il
//     job: è la riga — che le funzioni di fase aggiornano — a dire se continuare, non il corpo
//     della risposta. Un 409 `wrong_phase` (un altro driver è passato prima del lease, o una
//     ripresa) non è un errore: si rilegge e si riparte da ciò che la riga dice.
//   * **La push di fine import passa dalla coda `notifications`** (§7.2: "una push lo avvisa a
//     fine import"), non da una chiamata FCM diretta: `process-notifications` conosce token,
//     preferenze e il tetto giornaliero, e duplicarlo qui sarebbe il modo di mandare push a chi
//     le ha spente. Se l'insert fallisce il report resta comunque nel job: la push è un avviso,
//     non la fonte.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''

/** La chiave con cui il driver chiama le funzioni di fase: le loro guardie (`isServiceCaller`)
 *  la riconoscono. Stessa risoluzione di `proxy.ts`: prima la chiave nuova, poi la legacy. */
const SERVICE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()

/** Fase → funzione che la fa avanzare. `done` non c'è: un job `done` non è più `running`. */
const PHASE_FN: Record<string, string> = {
  uploaded: 'import-parse',
  parsing: 'import-parse',
  resolving: 'import-resolve',
  writing: 'import-write',
  recomputing: 'import-finalize',
}

/** Budget dell'invocazione. NON è il limite di piattaforma (~150 s) a deciderlo: è il cron.
 *  Un giro che finisce prima del tick successivo (60 s) significa UN flusso solo anche quando
 *  il lease non è reclamabile (replica PostgREST con cache stantia, visto in produzione): il
 *  primo import vero, con due giri sovrapposti senza lease, ha tenuto ~20 chiamate TMDB
 *  simultanee per 9 minuti e si è preso ~30 minuti di 500 — il ban da scraper contro cui
 *  mette in guardia il commento di FIND_CONCURRENCY. 40 s + la chiamata di fase più lunga
 *  osservata resta sotto il minuto. */
const RUN_BUDGET_MS = 40_000
/** Il lease: rinnovato prima di ogni chiamata di fase, deve coprire la più lenta (~90 s). */
const LEASE_MS = 180_000
/** Job per giro. Più utenti importano insieme, più giri servono: il cron è ogni minuto. */
const JOBS_PER_RUN = 3

type JobRow = {
  id: string
  user_id: string
  phase: string
  status: string
}

serve(async (req: Request) => {
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  const admin = adminClient()
  const deadline = Date.now() + RUN_BUDGET_MS
  const esiti: Record<string, unknown>[] = []

  const { data: jobs, error: jobsError } = await admin
    .from('import_jobs')
    .select('id, user_id, phase, status')
    .eq('status', 'running')
    .order('created_at', { ascending: true })
    .limit(JOBS_PER_RUN)

  if (jobsError) return jsonResponse({ error: 'jobs_lookup_failed', detail: jobsError.message }, 500)
  if (!jobs || jobs.length === 0) return jsonResponse({ jobs: 0 }, 200)

  for (const job of jobs as JobRow[]) {
    if (Date.now() >= deadline) break

    // Claim atomico: la riga si aggiorna solo se il lease è libero o scaduto. Zero righe
    // aggiornate = un altro driver ce l'ha: non è un errore, si passa oltre.
    //
    // Le virgolette attorno al timestamp sono l'igiene che PostgREST chiede per i valori con
    // caratteri riservati dentro `or=()`. NON sono state la cura del 42703 visto al collaudo:
    // quella era una replica PostgREST con la schema cache stantia (stessa richiesta, 400 e
    // poi 204 a secondi di distanza) — vedi il ramo `claimError` qui sotto.
    const { data: claimed, error: claimError } = await admin
      .from('import_jobs')
      .update({ locked_until: new Date(Date.now() + LEASE_MS).toISOString() })
      .eq('id', job.id)
      .eq('status', 'running')
      .or(`locked_until.is.null,locked_until.lt."${new Date().toISOString()}"`)
      .select('id')

    if (claimError) {
      // Il lease non si riesce nemmeno a scrivere (visto in produzione: una replica PostgREST
      // con la schema cache stantia non conosceva `locked_until` e rispondeva 42703 su una
      // colonna che esiste). Si procede SENZA lease, e lo si dice: la correttezza non dipende
      // dal lease — le fasi sono checkpointed e la fase 4 deduplica per `dedup_key`, quindi
      // due driver sovrapposti sprecano lavoro, non duplicano dati (criterio 2 di §13).
      // Il lease è un'ottimizzazione; un errore qui è rumore da sistemare (NOTIFY pgrst /
      // riavvio PostgREST), non una ragione per lasciare l'import fermo per sempre.
      esiti.push({ job: job.id, esito: `claim fallito, si procede senza lease: ${claimError.message}` })
    } else if (!claimed || claimed.length === 0) {
      // Zero righe = il lease ce l'ha un altro driver, vivo: qui sì che si passa oltre.
      esiti.push({ job: job.id, esito: 'lease occupato' })
      continue
    }

    let corrente: JobRow = job
    let passi = 0

    while (Date.now() < deadline) {
      const fn = PHASE_FN[corrente.phase]
      if (!fn || corrente.status !== 'running') break

      // Rinnovo del lease PRIMA della chiamata: è la chiamata la cosa lenta da coprire.
      await admin.from('import_jobs')
        .update({ locked_until: new Date(Date.now() + LEASE_MS).toISOString() })
        .eq('id', corrente.id)

      const risposta = await fetch(`${SUPABASE_URL}/functions/v1/${fn}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': SERVICE_KEY,
          'Authorization': `Bearer ${SERVICE_KEY}`,
        },
        body: JSON.stringify({ job_id: corrente.id }),
      })
      passi += 1

      // Il corpo serve solo alla push di fine import; per tutto il resto fa fede la riga.
      let corpo: Record<string, unknown> = {}
      try { corpo = await risposta.json() } catch { /* la rilettura decide comunque */ }

      const { data: riletto } = await admin
        .from('import_jobs')
        .select('id, user_id, phase, status')
        .eq('id', corrente.id)
        .maybeSingle()
      if (!riletto) break
      corrente = riletto as JobRow

      if (corrente.phase === 'done' || corrente.status === 'done') {
        // §7.2: la push di fine import. Nella coda, non a FCM: vedi il commento in testa.
        const report = (corpo.report ?? {}) as Record<string, unknown>
        const episodi = Number(report.episodi_importati ?? 0)
        const serie = Number(report.serie_importate ?? 0)
        const irrisolti = Number(report.non_riconosciuti_episodi ?? 0)
        const { error: pushError } = await admin.from('notifications').insert({
          user_id: corrente.user_id,
          notification_type: 'import_done',
          title: 'Import finished',
          body: irrisolti > 0
            ? `${episodi} episodes from ${serie} shows imported. ${irrisolti} items need review.`
            : `${episodi} episodes from ${serie} shows imported.`,
          is_sent: false,
          category: 'import_done',
          thread_id: 'import',
          template_key: 'import_done',
          template_params: { episodes: episodi, shows: serie, pending: irrisolti },
        })
        if (pushError) console.error(`[import-driver] push non accodata per ${corrente.id}: ${pushError.message}`)
        break
      }

      if (corpo.retry === true) {
        // La fase ha incontrato un errore transitorio a valle (es. catalog-resolve 500) e ha
        // scelto di riprovare: il job resta `running`, ma martellarlo ADESSO colpirebbe un
        // servizio che sta già rispondendo male. Si passa oltre; il prossimo tick riprova.
        break
      }

      if (!risposta.ok && risposta.status !== 409) {
        // Le funzioni di fase marcano da sole il job `failed` sui propri errori; un errore di
        // trasporto qui non ha toccato la riga e il prossimo giro riprova dal checkpoint.
        console.error(`[import-driver] ${fn} su ${corrente.id}: HTTP ${risposta.status}`)
        break
      }
    }

    // Lease rilasciato esplicitamente: il prossimo giro non deve aspettarne la scadenza.
    await admin.from('import_jobs')
      .update({ locked_until: null })
      .eq('id', corrente.id)

    esiti.push({ job: corrente.id, fase: corrente.phase, stato: corrente.status, passi })
  }

  return jsonResponse({ jobs: jobs.length, esiti }, 200)
})
