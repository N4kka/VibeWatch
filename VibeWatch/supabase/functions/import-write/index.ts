// Fase 4 dell'import TV Time (SPEC v3 §7.2): da `import_staging` a `watch_events`.
//
// Le regole stanno in `mutations.ts`, che è puro e testato. Qui c'è l'I/O e le tre cose che
// rendono questa fase diversa dalle precedenti:
//
//   * **`apply_mutations` gira come il chiamante, non come admin.** La funzione è `security
//     definer` ma si àncora ad `auth.uid()`: chiamata con la chiave di servizio solleva
//     `unauthenticated`. È anche giusto così — è l'utente che sta importando nel proprio account.
//   * **L'idempotenza non è del checkpoint ma della `dedup_key`.** Rigiocare lo stesso lotto non
//     duplica niente (criterio 2 di §13), quindi riprendere dal punto sbagliato costa lavoro, mai
//     dati doppi.
//   * **Un evento che non si può scrivere non si scrive approssimato.** Torna con la sua ragione
//     in `import_staging.error` e finisce nel report di §7.4: un import che dice "fatto" avendo
//     perso 200 episodi è peggio di uno che dichiara il problema.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'
import { buildBatch, type StagingRow } from './mutations.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

/**
 * Client che parla con il JWT del chiamante.
 *
 * Serve a due cose diverse e non intercambiabili: leggere il job facendo decidere la policy
 * invece di un `if` (è così che è nato l'IDOR di `import-parse`, riprodotto fra due utenti prima
 * di chiuderlo), e chiamare `apply_mutations`, che senza `auth.uid()` non parte.
 */
function callerClient(req: Request) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false },
  })
}

/**
 * Righe lette per invocazione. Il tetto vero non è la memoria ma lo `statement_timeout = 8s` del
 * ruolo `authenticated`: `apply_mutations` cicla per elemento e ogni insert fa scattare il trigger
 * di ricalcolo, quindi il lotto va tenuto piccolo e le invocazioni tante.
 */
const ROWS_PER_INVOCATION = 500
/** Mutazioni per chiamata a `apply_mutations`. */
const MUTATIONS_PER_CALL = 100

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
  const caller = callerClient(req)

  const { data: job, error: jobError } = await caller
    .from('import_jobs')
    .select('id, user_id, phase, status, totals')
    .eq('id', jobId)
    .maybeSingle()

  if (jobError) return jsonResponse({ error: 'job_lookup_failed', detail: jobError.message }, 401)
  if (!job) return jsonResponse({ error: 'job_not_found' }, 404)
  if (job.phase !== 'writing') return jsonResponse({ error: 'wrong_phase', phase: job.phase }, 409)

  try {
    const { data: pending, error: readError } = await admin
      .from('import_staging')
      .select('row_index, raw, resolved, status')
      .eq('job_id', jobId)
      .eq('status', 'resolved')
      .eq('raw->>row_kind', 'event')
      .order('row_index', { ascending: true })
      .limit(ROWS_PER_INVOCATION)

    if (readError) throw new Error(`lettura staging fallita: ${readError.message}`)

    if (!pending || pending.length === 0) {
      // Niente più eventi da scrivere: si chiudono i voti e si passa alla fase successiva.
      const rimandati = await deferRatings(admin, jobId)

      const totals = {
        ...(job.totals as Record<string, unknown> ?? {}),
        ratings_deferred: rimandati,
      }

      const { error } = await admin.from('import_jobs')
        .update({ phase: 'recomputing', checkpoint: {}, totals }).eq('id', jobId)
      if (error) throw new Error(`avanzamento non salvato: ${error.message}`)

      return jsonResponse({ done: true, phase: 'recomputing', written: 0, totals }, 200)
    }

    const { mutations, written, skipped } = buildBatch(pending as StagingRow[], job.user_id)

    // `apply_mutations` non torna un esito per elemento: quello che rifiuta lo scrive in
    // `sync_rejected_mutations` e prosegue. Si conta prima e si confronta dopo, altrimenti una
    // perdita parziale passerebbe per un successo.
    const rifiutiPrima = await countRejected(admin, job.user_id)

    for (let i = 0; i < mutations.length; i += MUTATIONS_PER_CALL) {
      const lotto = mutations.slice(i, i + MUTATIONS_PER_CALL)
      const { error } = await caller.rpc('apply_mutations', { batch: lotto })
      if (error) throw new Error(`apply_mutations ha rifiutato il lotto a ${i}: ${error.message}`)
    }

    const rifiutiDopo = await countRejected(admin, job.user_id)
    const nuoviRifiuti = rifiutiDopo - rifiutiPrima
    if (nuoviRifiuti > 0) {
      // Fallisce rumorosamente: un rifiuto qui vuol dire eventi persi, ed è esattamente il tipo
      // di perdita che questa pipeline esiste per non fare in silenzio.
      throw new Error(
        `${nuoviRifiuti} mutazioni rifiutate da apply_mutations: guardare sync_rejected_mutations`,
      )
    }

    if (written.length > 0) {
      const { error } = await admin.from('import_staging')
        .update({ status: 'written', error: null })
        .eq('job_id', jobId)
        .in('row_index', written)
      if (error) throw new Error(`marcatura righe scritte fallita: ${error.message}`)
    }

    // I saltati si marcano uno per uno perché ognuno porta la propria ragione: è il materiale
    // dell'elenco dei non riconosciuti che §7.4 rende obbligatorio.
    for (const { row_index, reason } of skipped) {
      const { error } = await admin.from('import_staging')
        .update({ status: 'skipped', error: `scrittura: ${reason}` })
        .eq('job_id', jobId).eq('row_index', row_index)
      if (error) throw new Error(`marcatura riga ${row_index} fallita: ${error.message}`)
    }

    const totaliPrecedenti = (job.totals as Record<string, number>) ?? {}
    const totals = {
      ...(job.totals as Record<string, unknown> ?? {}),
      written: (totaliPrecedenti.written ?? 0) + written.length,
      not_written: (totaliPrecedenti.not_written ?? 0) + skipped.length,
    }

    const { error: updateError } = await admin.from('import_jobs')
      .update({ totals }).eq('id', jobId)
    if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

    return jsonResponse({
      done: false,
      phase: 'writing',
      written: written.length,
      skipped: skipped.length,
      totals,
    }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    await admin.from('import_jobs')
      .update({ status: 'failed', error: message.slice(0, 500) }).eq('id', jobId)
    return jsonResponse({ error: 'write_failed', detail: message }, 500)
  }
})

/**
 * Quante mutazioni di questo utente sono già finite nello scarto.
 *
 * Si somma `occurrences`, **non** si contano le righe: `sync_rejected_mutations` è aggregata per
 * (utente, tabella, ragione, giorno), quindi cento rifiuti dello stesso tipo nello stesso giorno
 * lasciano il numero di righe identico e incrementano un contatore. Contare le righe avrebbe
 * detto "nessun rifiuto nuovo" proprio nel caso peggiore — un intero lotto perso.
 */
async function countRejected(
  admin: ReturnType<typeof adminClient>,
  userId: string,
): Promise<number> {
  const { data, error } = await admin
    .from('sync_rejected_mutations')
    .select('occurrences')
    .eq('user_id', userId)
  if (error) throw new Error(`conteggio dei rifiuti fallito: ${error.message}`)
  return (data ?? []).reduce((sum, r) => sum + (r.occurrences ?? 0), 0)
}

/**
 * I voti restano fuori da questa release, e lo dicono.
 *
 * `user_ratings` (§3.6) arriva col blocco 9: oggi la tabella non esiste e `apply_mutations` non
 * ha un ramo per lei. Lasciare le righe `pending` le renderebbe indistinguibili da lavoro ancora
 * da fare; marcarle `skipped` con la ragione le rende ritrovabili quando la tabella ci sarà, e
 * soprattutto le fa comparire nel report invece di sparire.
 */
async function deferRatings(
  admin: ReturnType<typeof adminClient>,
  jobId: string,
): Promise<number> {
  const { data, error } = await admin.from('import_staging')
    .update({ status: 'skipped', error: 'voti: user_ratings arriva col blocco 9 (§3.6)' })
    .eq('job_id', jobId)
    .eq('status', 'pending')
    .eq('raw->>row_kind', 'rating')
    .select('row_index')

  if (error) throw new Error(`rinvio dei voti fallito: ${error.message}`)
  return data?.length ?? 0
}
