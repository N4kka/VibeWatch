// Risoluzione A MANO dei non riconosciuti (SPEC v3 §7.4: "con la possibilità di risolverli
// a mano" — fino a oggi si elencavano e basta).
//
// L'utente dichiara soltanto l'identità della SERIE. La funzione salva quella scelta e rimette
// in `pending` i fallimenti di catalogo; poi riapre il job in `resolving`. La pipeline esistente
// ritenta ogni `tvdb_episode_id` tramite TMDB `/find`, in batch/checkpoint, e usa la serie scelta
// esclusivamente come filtro dei risultati esatti. Stagione e numero dell'export non vengono mai
// letti qui e non possono diventare identità episodio (§6).
//
// Solo utenti (JWT): la lettura del job passa dalla RLS (`import_jobs_select_own`), che decide
// come sempre — la lezione dell'IDOR di import-parse. Il cron non chiama mai questa funzione.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'
import { buildManualRetryPlan, RetryStagingRow } from './retry.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

/** Blocchi di lettura sullo staging: PostgREST tronca a 1000, ci si sta sotto. */
const ROWS_PER_PAGE = 1_000

function callerClient(req: Request) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false },
  })
}

serve(async (req: Request) => {
  try {
    return await handle(req)
  } catch (err) {
    const message = err instanceof Error ? (err.stack ?? err.message) : String(err)
    console.error(`[import-manual-resolve] eccezione non gestita: ${message}`)
    return jsonResponse({ error: 'internal', detail: message.slice(0, 400) }, 500)
  }
})

async function handle(req: Request): Promise<Response> {
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405)

  let jobId: string
  let tvdbSeriesId: string
  let tvdbIdNum: number
  let tmdbShowId: number
  try {
    const body = await req.json()
    jobId = String(body.job_id ?? '')
    tvdbIdNum = Number(body.tvdb_series_id)
    tvdbSeriesId = String(tvdbIdNum)
    tmdbShowId = Number(body.tmdb_show_id)
    if (jobId === '' || !Number.isSafeInteger(tvdbIdNum) || tvdbIdNum <= 0) {
      throw new Error('campi')
    }
    if (!Number.isSafeInteger(tmdbShowId) || tmdbShowId <= 0) throw new Error('tmdb_show_id')
  } catch {
    return jsonResponse({ error: 'invalid_request' }, 400)
  }

  const admin = adminClient()

  // Il job come lo vede il chiamante: la policy decide se esiste.
  const { data: job, error: jobError } = await callerClient(req)
    .from('import_jobs')
    .select('id, user_id, phase, status, totals')
    .eq('id', jobId)
    .maybeSingle()
  if (jobError) return jsonResponse({ error: 'job_lookup_failed', detail: jobError.message }, 401)
  if (!job) return jsonResponse({ error: 'job_not_found' }, 404)
  // Solo un job arrivato in fondo: riaprirne uno in corsa significherebbe due scritture
  // concorrenti sulle stesse righe di staging.
  if (job.phase !== 'done' || job.status !== 'done') {
    return jsonResponse({ error: 'job_not_done', phase: job.phase, status: job.status }, 409)
  }

  // La mappa serie: mai sopra una riga già buona. Se la mappa dice che questa serie TVDB È
  // un'altra serie TMDB, qualcuno (o un altro import) l'ha già risolta: si risponde il
  // conflitto invece di riscrivere la verità condivisa (§1.5).
  const { data: mapRow, error: mapReadError } = await admin
    .from('tvdb_tmdb_map')
    .select('tvdb_id, resolution, tmdb_show_id')
    .eq('tvdb_id', tvdbIdNum)
    .eq('entity_type', 'series')
    .maybeSingle()
  if (mapReadError) {
    return jsonResponse({ error: 'map_read_failed', detail: mapReadError.message }, 500)
  }
  if (mapRow?.resolution === 'found' && mapRow.tmdb_show_id !== tmdbShowId) {
    return jsonResponse({
      error: 'series_already_mapped',
      tmdb_show_id: mapRow.tmdb_show_id,
    }, 409)
  }

  // Le sole righe che hanno fallito nel CATALOGO. Un rifiuto di scrittura (`gia_in_app`,
  // `senza_dedup_key`, ecc.) e' una decisione gia' presa e non deve risorgere perche' l'utente
  // ha scelto una serie. X Factor supera 1000 righe: paginazione esplicita, mai il default.
  const righeSerie: RetryStagingRow[] = []
  for (let cursore = -1; ;) {
    const { data, error } = await admin
      .from('import_staging')
      .select('row_index, raw, resolved, status, error')
      .eq('job_id', jobId)
      .eq('raw->>tvdb_series_id', tvdbSeriesId)
      .eq('status', 'unresolved')
      .in('raw->>row_kind', ['event', 'status', 'favorite'])
      .gt('row_index', cursore)
      .order('row_index', { ascending: true })
      .limit(ROWS_PER_PAGE)
    if (error) return jsonResponse({ error: 'staging_read_failed', detail: error.message }, 500)
    if (!data || data.length === 0) break
    righeSerie.push(...(data as RetryStagingRow[]))
    cursore = data[data.length - 1].row_index
    if (data.length < ROWS_PER_PAGE) break
  }

  // I voti non portano un tvdb_series_id affidabile. Si riaprono soltanto quelli gia' dichiarati
  // `non_risolto` il cui id episodio appartiene agli eventi selezionati; ogni altro skip resta.
  const preliminare = buildManualRetryPlan(
    righeSerie, [], (job.totals ?? {}) as Record<string, unknown>)
  const righeVoti: RetryStagingRow[] = []
  for (let i = 0; i < preliminare.episodeIds.length; i += 200) {
    const ids = preliminare.episodeIds.slice(i, i + 200).map(String)
    for (let cursore = -1; ;) {
      const { data, error } = await admin
        .from('import_staging')
        .select('row_index, raw, resolved, status, error')
        .eq('job_id', jobId)
        .eq('raw->>row_kind', 'rating')
        .eq('status', 'skipped')
        .eq('error', 'voti: non_risolto')
        .in('raw->>tvdb_episode_id', ids)
        .gt('row_index', cursore)
        .order('row_index', { ascending: true })
        .limit(ROWS_PER_PAGE)
      if (error) return jsonResponse({ error: 'ratings_read_failed', detail: error.message }, 500)
      if (!data || data.length === 0) break
      righeVoti.push(...(data as RetryStagingRow[]))
      cursore = data[data.length - 1].row_index
      if (data.length < ROWS_PER_PAGE) break
    }
  }
  righeVoti.sort((a, b) => a.row_index - b.row_index)

  // Un episodio `found` è finale. Se appartiene a un'altra serie, l'evento resta un conflitto e
  // il voto collegato NON deve riaprirsi: la fase 4 usa la mappa globale e lo scriverebbe sullo
  // show sbagliato. Le mappe assenti/non finali sono invece sicure: potranno produrre un voto
  // solo se il retry esatto le trasforma in `found` per la serie scelta.
  const episodiVotoInConflitto = new Set<number>()
  for (let i = 0; i < preliminare.episodeIds.length; i += 500) {
    const { data, error } = await admin
      .from('tvdb_tmdb_map')
      .select('tvdb_id, resolution, tmdb_show_id')
      .eq('entity_type', 'episode')
      .in('tvdb_id', preliminare.episodeIds.slice(i, i + 500))
    if (error) return jsonResponse({ error: 'episode_map_read_failed', detail: error.message }, 500)
    for (const row of data ?? []) {
      if (row.resolution === 'found' && row.tmdb_show_id !== tmdbShowId) {
        episodiVotoInConflitto.add(Number(row.tvdb_id))
      }
    }
  }

  const piano = buildManualRetryPlan(
    righeSerie,
    righeVoti,
    (job.totals ?? {}) as Record<string, unknown>,
    episodiVotoInConflitto,
  )
  if (piano.rows.length === 0) return jsonResponse({ error: 'nothing_to_resolve' }, 404)

  // Mappa SERIE, staging e job sono una decisione sola. La RPC applica tutto in una
  // transazione: se l'indice rifiuta un altro job aperto (o una riga cambia nel frattempo),
  // il report e la mappa condivisa restano intatti. Le mappe EPISODIO non vengono mai scritte
  // qui: saranno esclusivamente il risultato di `/find(tvdb_episode_id)` in `resolving`.
  const { data: reopen, error: reopenError } = await admin.rpc(
    'import_reopen_manual_resolution',
    {
      p_job_id: jobId,
      p_tvdb_series_id: tvdbIdNum,
      p_tmdb_show_id: tmdbShowId,
      p_row_indexes: piano.rows.map((row) => row.row_index),
      p_totals: piano.adjustedTotals,
    },
  )
  if (reopenError) {
    return jsonResponse({ error: 'atomic_reopen_failed', detail: reopenError.message }, 500)
  }

  const outcome = (reopen ?? {}) as {
    ok?: boolean
    reason?: string
    tmdb_show_id?: number
  }
  if (!outcome.ok) {
    const reason = outcome.reason ?? 'reopen_failed'
    const status = reason === 'invalid_plan' ? 400
      : ['another_job_open', 'job_not_done', 'series_already_mapped', 'staging_changed']
          .includes(reason) ? 409
      : 500
    return jsonResponse({
      error: reason,
      ...(outcome.tmdb_show_id == null ? {} : { tmdb_show_id: outcome.tmdb_show_id }),
    }, status)
  }

  return jsonResponse({
    ok: true,
    eventi_da_ritentare: piano.counts.events,
    stati_da_ritentare: piano.counts.statuses,
    favorites_da_ritentare: piano.counts.favorites,
    voti_da_ritentare: piano.counts.ratings,
    phase: 'resolving',
  }, 200)
}
