// Fasi 5 e 6 dell'import TV Time (SPEC v3 §7.2): `recomputing` e `done`.
//
// Stanno nella stessa funzione perché la fase 5 è quasi vuota e la 6 dipende solo dal suo esito.
//
// **Perché la fase 5 esiste anche se non serve.** Il trigger `watch_events_recompute_insert` è
// statement-level e ricalcola ogni `(utente, serie)` toccata da ogni INSERT, quindi a fine fase 4
// `tv_show_state` è già corretto — misurato: 100 insert con trigger costano 250 ms, un ricalcolo
// singolo 2,6 ms. Il giro finale resta perché costa ~1 s su 430 serie ed è ciò che garantisce che
// un job interrotto fra due lotti, o ripreso dopo un fallimento, finisca comunque consistente.
//
// **Perché il ricalcolo gira come admin e non come il chiamante**, al contrario della fase 4:
// `recompute_tv_show_state(uuid, integer)` prende un `user_id` arbitrario e per questo NON è
// eseguibile da `authenticated` — verificato con `has_function_privilege`. È lavoro del server, e
// il job a cui si riferisce è già stato riconosciuto come proprio leggendolo col JWT.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'
import { isServiceCaller } from '../_shared/cronAuth.ts'
import { applyImportedTimezone, type TimezonePreferenceStore } from './profile.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

/** Serie ricalcolate per invocazione. A 2,6 ms l'una, 200 stanno larghe nel timeout. */
const SHOWS_PER_INVOCATION = 200

function callerClient(req: Request) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false },
  })
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
  // Utente → RLS decide (chiusura dell'IDOR); driver del cron (§7.2, app chiusa) → service
  // key, che nessun client possiede. Stessa coppia di strade delle altre fasi.
  const lookup = isServiceCaller(req) ? admin : callerClient(req)

  const { data: job, error: jobError } = await lookup
    .from('import_jobs')
    .select('id, user_id, phase, status, checkpoint, totals')
    .eq('id', jobId)
    .maybeSingle()

  if (jobError) return jsonResponse({ error: 'job_lookup_failed', detail: jobError.message }, 401)
  if (!job) return jsonResponse({ error: 'job_not_found' }, 404)
  if (job.phase !== 'recomputing') {
    return jsonResponse({ error: 'wrong_phase', phase: job.phase }, 409)
  }

  try {
    // Le serie toccate da QUESTO job, non tutte quelle dell'utente: un import non deve rimettere
    // mano allo stato di serie che non ha importato.
    const checkpoint = (job.checkpoint ?? {}) as { last_show_id?: number }
    const da = checkpoint.last_show_id ?? 0

    const { data: elenco, error: readError } = await admin.rpc('import_touched_shows', {
      p_job_id: jobId,
      p_after: da,
      p_limit: SHOWS_PER_INVOCATION,
    })

    if (readError) throw new Error(`lettura serie toccate fallita: ${readError.message}`)

    const serie = (elenco ?? []) as number[]

    if (serie.length > 0) {
      for (const showId of serie) {
        const { error } = await admin.rpc('recompute_tv_show_state', {
          p_user_id: job.user_id,
          p_tmdb_show_id: showId,
        })
        if (error) throw new Error(`ricalcolo di ${showId} fallito: ${error.message}`)
      }

      const { error } = await admin.from('import_jobs')
        .update({ checkpoint: { last_show_id: serie[serie.length - 1] } })
        .eq('id', jobId)
      if (error) throw new Error(`checkpoint non salvato: ${error.message}`)

      return jsonResponse({
        done: false,
        phase: 'recomputing',
        ricalcolate: serie.length,
        ultima: serie[serie.length - 1],
      }, 200)
    }

    // §7.1: il timezone di user.csv → quiet hours. PRIMA del report, così l'esito finisce nei
    // totals che il report archivia. Tre regole: mai sopra un valore già scelto (in app o da un
    // import precedente — il guard `is('timezone', null)` chiude anche la corsa); un profilo
    // senza riga si crea con il solo timezone (il resto sono i default); un errore qui si
    // dichiara nei totals e NON fa fallire il job — il fuso è un contorno, l'import no.
    const timezoneStore: TimezonePreferenceStore = {
      async read(userId) {
        const { data: pref, error: readError } = await admin
          .from('user_notification_preferences')
          .select('timezone')
          .eq('user_id', userId)
          .maybeSingle()
        if (readError) throw new Error(readError.message)
        return { exists: pref !== null, timezone: pref?.timezone ?? null }
      },

      async insertIfAbsent(userId, timezone) {
        const { data, error } = await admin
          .from('user_notification_preferences')
          .upsert(
            { user_id: userId, timezone },
            { onConflict: 'user_id', ignoreDuplicates: true },
          )
          .select('user_id')
          .maybeSingle()
        if (error) throw new Error(error.message)
        return data !== null
      },

      async updateIfUnset(userId, timezone) {
        const { data, error } = await admin
          .from('user_notification_preferences')
          .update({ timezone })
          .eq('user_id', userId)
          .is('timezone', null)
          .select('user_id')
          .maybeSingle()
        if (error) throw new Error(error.message)
        return data !== null
      },
    }
    const tzEsito = await applyImportedTimezone(
      (job.totals as Record<string, unknown> | null)?.['user_timezone'],
      job.user_id,
      timezoneStore,
    )

    const { error: tzTotalsError } = await admin.from('import_jobs')
      .update({ totals: { ...(job.totals as Record<string, unknown> ?? {}), timezone_quiet_hours: tzEsito } })
      .eq('id', jobId)
    if (tzTotalsError) throw new Error(`esito timezone non salvato: ${tzTotalsError.message}`)

    // Fase 6. Il report si costruisce PRIMA di dichiarare il job finito: se fallisce, il job resta
    // in `recomputing` e ci si riprova, invece di restare `done` senza saper dire cosa è successo.
    const { data: report, error: reportError } = await admin
      .rpc('import_report', { p_job_id: jobId })
    if (reportError) throw new Error(`report non generato: ${reportError.message}`)

    // Il report viene calcolato mentre il job è ancora `recomputing`, quindi la fotografia che si
    // archivia direbbe "status: running" per sempre. Si sovrascrivono i due campi qui, in modo
    // esplicito, invece di rigenerare il report dopo la chiusura: rigenerarlo vorrebbe dire un
    // secondo giro che, fallendo, lascerebbe un job `done` con un report che si contraddice.
    const reportFinale = { ...(report as Record<string, unknown>), phase: 'done', status: 'done' }
    // `timezone_quiet_hours` va ripetuto qui: `job.totals` è la riga letta a inizio invocazione,
    // PRIMA dell'update qui sopra — spreadarla da sola cancellerebbe l'esito appena scritto.
    const totals = {
      ...(job.totals as Record<string, unknown> ?? {}),
      timezone_quiet_hours: tzEsito,
      report: reportFinale,
    }

    const { error: closeError } = await admin.from('import_jobs')
      .update({ phase: 'done', status: 'done', checkpoint: {}, totals, error: null })
      .eq('id', jobId)
    if (closeError) throw new Error(`chiusura del job fallita: ${closeError.message}`)

    return jsonResponse({ done: true, phase: 'done', report: reportFinale }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    await admin.from('import_jobs')
      .update({ status: 'failed', error: message.slice(0, 500) }).eq('id', jobId)
    return jsonResponse({ error: 'finalize_failed', detail: message }, 500)
  }
})
