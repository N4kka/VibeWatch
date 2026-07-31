// Fase 2 dell'import TV Time (SPEC v3 §7.2): dallo ZIP in Storage a `import_staging`.
//
// Le regole di parsing stanno in `parsing.ts`, che è puro e testato contro l'oracolo. Qui c'è solo
// l'I/O: scaricare, decomprimere, leggere i CSV, scrivere lo staging e spostare il checkpoint.
//
// **Perché una invocazione non basta.** Un export reale è 21.344 eventi e una Edge Function ha un
// muro di wall-clock. La funzione quindi scrive un blocco per volta e risponde `done: false`
// finché ne resta: il chiamante torna. Il costo di questo disegno è che ogni invocazione
// ri-scarica e ri-analizza lo ZIP, perché `assignRewatchIndex` ha bisogno di *tutti* gli eventi di
// un episodio per numerarli — non è parallelizzabile per righe. È un costo accettabile: il parsing
// di 21k righe è millisecondi, mentre perdere il lavoro a metà non lo è.
//
// L'idempotenza non dipende dal checkpoint: `import_staging` ha chiave (job_id, row_index) e si
// scrive in upsert. Riprendere dal punto sbagliato duplica nulla, al massimo rifà lavoro.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'
import { buildRows, FILE_V1, FILE_V2, RATING_FILES, readCsvEntries } from './archive.ts'

/** Righe di staging scritte per invocazione. */
const ROWS_PER_INVOCATION = 4_000
/** Righe per singola INSERT: oltre questa soglia il payload inizia a pesare più del round-trip. */
const ROWS_PER_INSERT = 500

interface StagingRow {
  job_id: string
  row_index: number
  raw: Record<string, unknown>
  status: string
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

  const { data: job, error: jobError } = await admin
    .from('import_jobs')
    .select('id, user_id, phase, status, storage_path, checkpoint, totals')
    .eq('id', jobId)
    .maybeSingle()

  if (jobError) return jsonResponse({ error: 'job_lookup_failed', detail: jobError.message }, 500)
  if (!job) return jsonResponse({ error: 'job_not_found' }, 404)
  if (!job.storage_path) return jsonResponse({ error: 'job_has_no_upload' }, 409)

  // Rifiuta di ripartire un job già oltre questa fase: riscrivere lo staging sotto una fase di
  // scrittura in corso significherebbe cambiare i dati mentre qualcuno li sta importando.
  if (job.phase !== 'uploaded' && job.phase !== 'parsing') {
    return jsonResponse({ error: 'wrong_phase', phase: job.phase }, 409)
  }

  try {
    const { data: blob, error: downloadError } = await admin.storage
      .from('imports')
      .download(job.storage_path)

    if (downloadError || !blob) {
      throw new Error(`download fallito: ${downloadError?.message ?? 'nessun contenuto'}`)
    }

    const files = await readCsvEntries(blob, [FILE_V2, FILE_V1, ...RATING_FILES])
    if (!files.has(FILE_V2) && !files.has(FILE_V1)) {
      // Nessuno dei due file di tracking: non è un export TV Time, e dirlo subito è meglio che
      // importare zero eventi e dichiarare "fatto" (§7.4).
      throw new Error('lo ZIP non contiene né tracking-prod-records-v2.csv né tracking-prod-records.csv')
    }

    const { events, ratings, unusableV1, droppedV1 } = buildRows(files)

    // Un solo elenco ordinato: gli eventi e poi i voti. `row_index` è la posizione qui dentro, ed è
    // ciò che rende la ripresa un numero invece che una ricerca.
    const staged: StagingRow[] = [
      // `row_kind` e non `kind`: `ParsedRating` ha già un `kind` suo (star/reaction), e uno spread
      // sopra un discriminatore omonimo lo sovrascriverebbe in silenzio — la fase di scrittura
      // smisterebbe i voti come se fossero eventi. Il compilatore l'ha vista, ma il nome distinto
      // è ciò che impedisce che ritorni.
      ...events.map((e, i) => ({
        job_id: jobId,
        row_index: i,
        raw: { row_kind: 'event', ...e } as Record<string, unknown>,
        status: 'pending',
      })),
      ...ratings.map((r, i) => ({
        job_id: jobId,
        row_index: events.length + i,
        raw: { row_kind: 'rating', ...r } as Record<string, unknown>,
        status: 'pending',
      })),
    ]

    const checkpoint = (job.checkpoint ?? {}) as { row_index?: number }
    const from = Math.max(0, checkpoint.row_index ?? 0)
    const to = Math.min(staged.length, from + ROWS_PER_INVOCATION)

    for (let i = from; i < to; i += ROWS_PER_INSERT) {
      const slice = staged.slice(i, Math.min(to, i + ROWS_PER_INSERT))
      const { error } = await admin
        .from('import_staging')
        .upsert(slice, { onConflict: 'job_id,row_index' })
      if (error) throw new Error(`staging fallito a row_index ${i}: ${error.message}`)
    }

    const done = to >= staged.length

    // I totali si aggiornano a ogni giro, non alla fine: se il job muore adesso, ciò che è stato
    // fatto resta dichiarato invece di sparire (§7.4).
    const totals = {
      ...(job.totals as Record<string, unknown> ?? {}),
      events: events.length,
      ratings: ratings.length,
      staged_rows: staged.length,
      v1_unusable: unusableV1,
      v1_dropped_as_duplicate: droppedV1,
    }

    const { error: updateError } = await admin
      .from('import_jobs')
      .update({
        phase: done ? 'resolving' : 'parsing',
        checkpoint: done ? {} : { row_index: to },
        totals,
        error: null,
      })
      .eq('id', jobId)

    if (updateError) throw new Error(`avanzamento non salvato: ${updateError.message}`)

    return jsonResponse({
      done,
      phase: done ? 'resolving' : 'parsing',
      staged_from: from,
      staged_to: to,
      totals,
    }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    // Il fallimento si scrive sul job: un import che si ferma senza dire perché è il modo in cui
    // l'utente scopre da solo che mancano 200 episodi.
    await admin.from('import_jobs')
      .update({ status: 'failed', error: message.slice(0, 500) })
      .eq('id', jobId)
    return jsonResponse({ error: 'parse_failed', detail: message }, 500)
  }
})
