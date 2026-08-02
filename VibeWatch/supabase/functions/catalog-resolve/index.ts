// TVDB -> TMDB resolution and catalog population (SPEC v3 §6, blocco 2 di §12).
//
// The ids in a TV Time export are TheTVDB's. Rather than add the TheTVDB API, each id is resolved
// once through TMDB's `/find` and stored in `tvdb_tmdb_map`, which is shared by every user: the
// first person to import a series pays the call, everyone after finds it already resolved.
//
// Auth is a user JWT — unlike youtube-search, this is not served to anonymous visitors. The budget
// is still there, because an import is 20.000 events and a bug in the client loop would otherwise
// discover that on TMDB's side.
//
// Bounded on purpose: resolution is a checkpointed background job (§7.2), not something that has
// to finish inside one HTTP request. When the deadline or the budget is reached the function
// returns what it did and lists what is left in `remaining`, and the caller comes back for more.
//
// The pure part (what a `/find` answer means, the refresh TTL, the episode flattening) lives in
// resolution.ts and is unit-tested: `deno test supabase/functions/catalog-resolve/`.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  adminClient,
  floorToDay,
  floorToHour,
  jsonResponse,
  refund,
  trySpend,
} from '../_shared/proxy.ts'
import {
  EntityType,
  episodeRowsFromSeasons,
  FindDiagnostics,
  findDiagnostics,
  FindResponse,
  initialSeasonChunk,
  MapRow,
  normalizeShowIds,
  resolveFromFind,
  SEASONS_PER_APPEND,
  seasonAppendChunks,
  SeasonPayload,
  seasonRange,
  shouldRetry,
  showRow,
  ShowPayload,
} from './resolution.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const SUPABASE_SERVICE_ROLE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) {
    try {
      const k = JSON.parse(s)?.default
      if (k) return k as string
    } catch { /* fall back */ }
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()
const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY') ?? ''
const TMDB_API_URL = 'https://api.themoviedb.org/3'
const PROVIDER = 'tmdb'

// §7.2: the import resolves in batches of 50.
const MAX_ENTITIES_PER_REQUEST = 50

// Budgets. TMDB does not publish a daily cap, so these exist to bound a runaway client loop, not
// to ration a scarce quota.
//
// **Perché ce ne sono due per chiamante.** La stima iniziale — "un import è ~430 find" — era
// sbagliata di cinquanta volte: le serie sono 430, ma gli **episodi** sono 21.189, e §6 vuole una
// `/find` per `tvdb_episode_id` perché TVDB e TMDB numerano diversamente. A 600 chiamate l'ora un
// import reale durava **35 ore**, ed era il tetto nostro a imporlo, non TMDB — misurato: TMDB non
// restituisce header di rate limit e accetta 30 chiamate in parallelo senza un solo 429.
//
// Allentare il tetto per tutti sarebbe stato il modo sbagliato: quel limite serve dove il
// chiamante è un'app che potrebbe andare in loop. Quindi resta 600 per l'uso normale, e c'è un
// secondo tetto molto più alto che si sblocca **solo presentando un `import_jobs` proprio e in
// fase `resolving`**. Il permesso di spendere non è un flag nella richiesta: è l'esistenza di un
// import vero, che nessuno può fabbricare perché su `import_jobs` non c'è policy di scrittura.
const CALLER_CALLS_PER_HOUR = 600
const IMPORT_CALLS_PER_HOUR = 30_000

// Il riscaldamento in background (`catalog-prewarm`) risolve la coda quando nessuno la sta
// aspettando, così il secondo utente che importa una serie popolare la trova già fatta (§1.5).
// Ha un tetto suo, sotto quello da import: se il budget globale è conteso, a perdere deve essere
// il lavoro che nessuno sta aspettando, non l'import di una persona che guarda la barra.
const PREWARM_CALLS_PER_HOUR = 10_000

// Un import completo è ~21.600 chiamate. A 50.000/giorno l'intera base utenti poteva farne 2,3 al
// giorno — il vincolo vero per una funzione di acquisizione (§10). 500.000/giorno sono ~23 primi
// import al giorno e, mediati sulle 24 ore, 5,8 richieste al secondo verso TMDB: ampiamente dentro
// ciò che regge. Restano un tetto: servono a fermare un guasto, non a razionare.
const GLOBAL_CALLS_PER_DAY = 500_000

// Stop starting new upstream calls after this. An Edge Function has a hard wall-clock limit, and
// being killed mid-batch would lose the rows resolved so far.
const DEADLINE_MS = 20_000

/**
 * How many `/find` calls are in flight at once.
 *
 * A `/find` is ~258 ms of pure round-trip (measured against TMDB from here), so resolving 50
 * entities one after another took ~13 s — most of the 20 s deadline, for a request that does
 * almost no work locally. A real import is 21.189 episodes: sequentially that is 1,5 hours of
 * wall-clock spent waiting, and it was the second half of why an import took a day and a half.
 *
 * 10 is deliberately modest. TMDB publishes no rate limit and answered 30 concurrent calls
 * without a single 429 (measured), but the reason to stay low is not their limit: it is that a
 * shared API key getting banned for looking like a scraper would cost far more than the minutes
 * saved. 10 keeps a 50-entity batch around 1,5 s, which is already the whole win.
 */
const FIND_CONCURRENCY = 10

interface RequestedEntity {
  tvdb_id: number
  entity_type: EntityType
}

interface Body {
  entities?: RequestedEntity[]
  /**
   * Id TMDB di serie da riscaldare direttamente, senza passare da `/find`. E' la strada di chi ha
   * gia' l'id giusto — il client, che identifica le serie per TMDB da sempre — e serve alla
   * migrazione dello storico del blocco 7. Puo' essere l'unico campo della richiesta.
   */
  show_ids?: number[]
  /** Set false to resolve ids without pulling the episode catalog (cheaper, for a first pass). */
  populate_episodes?: boolean
  /** Un `import_jobs` proprio e in fase `resolving`: sblocca il budget da import. */
  job_id?: string
}

const ENTITY_TYPES: EntityType[] = ['series', 'episode', 'movie']

serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  if (!TMDB_API_KEY) {
    console.error('[catalog-resolve] TMDB_API_KEY is not configured')
    return jsonResponse({ error: 'not_configured' }, 500)
  }

  const authHeader = req.headers.get('authorization') ?? req.headers.get('Authorization') ?? ''
  if (!authHeader.startsWith('Bearer ')) {
    return jsonResponse({ error: 'missing_authorization' }, 401)
  }

  const supabase = adminClient()
  const token = authHeader.slice('Bearer '.length)

  // Il riscaldamento in background non ha un utente: si autentica con la chiave di servizio, che
  // esiste solo lato server. E' un ramo esplicito e non un caso particolare di `getUser`, perche'
  // una chiave di servizio passata a `getUser` fallisce e basta — e un fallimento silenzioso qui
  // vorrebbe dire un cron che gira a vuoto per settimane senza che nessuno se ne accorga.
  const daServizio = SUPABASE_SERVICE_ROLE_KEY !== '' && token === SUPABASE_SERVICE_ROLE_KEY

  let userId = 'prewarm'
  if (!daServizio) {
    const { data: userResult, error: userError } = await supabase.auth.getUser(token)
    if (userError || !userResult?.user) {
      return jsonResponse({ error: 'invalid_token' }, 401)
    }
    userId = userResult.user.id
  }

  let body: Body
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400)
  }

  const requestedShowIds = normalizeShowIds(body.show_ids, MAX_ENTITIES_PER_REQUEST)
  if (requestedShowIds === null) {
    return jsonResponse({ error: 'show_ids must be positive tmdb show ids, at most 50' }, 400)
  }

  // `entities` resta obbligatorio quando e' l'unica cosa chiesta, ma una richiesta di solo
  // riscaldamento per id TMDB e' legittima e non deve inventarsi una lista TVDB vuota.
  const hasEntities = Array.isArray(body.entities) && body.entities.length > 0
  const entities = hasEntities ? normalizeEntities(body.entities) : []
  if (entities === null) {
    return jsonResponse({ error: 'entities must be [{tvdb_id, entity_type}], 1-50 items' }, 400)
  }
  if (entities.length === 0 && requestedShowIds.length === 0) {
    return jsonResponse({ error: 'entities or show_ids required' }, 400)
  }

  const populateEpisodes = body.populate_episodes !== false
  const now = new Date()
  const deadline = Date.now() + DEADLINE_MS

  // Il tetto da import si sblocca in due modi, con la stessa prova: un job vero in `resolving`.
  // Per un utente la verifica passa dal suo JWT (la policy decide, come dopo l'IDOR di
  // `import-parse`); per il driver del cron (§7.2, l'import ad app chiusa) un JWT utente non
  // esiste — il job si legge da admin e lo scope si intesta al PROPRIETARIO del job, non al
  // servizio: i contatori separati esistono perche' l'import non affami il prewarm e viceversa,
  // e finirebbero fusi proprio nei giri notturni in cui contano.
  let perImport = false
  let importOwner: string | null = null
  if (daServizio) {
    importOwner = await importJobOwner(supabase, body.job_id)
    perImport = importOwner !== null
  } else {
    perImport = await isImportInCorso(authHeader, body.job_id)
  }
  const callerScope = perImport
    ? `import:${daServizio ? importOwner : userId}`
    : (daServizio ? 'prewarm' : `user:${userId}`)
  const callerLimit = perImport
    ? IMPORT_CALLS_PER_HOUR
    : (daServizio ? PREWARM_CALLS_PER_HOUR : CALLER_CALLS_PER_HOUR)

  // 1. Cache first. A hit costs nothing: that is the whole point of a shared map.
  const stored = await readStoredRows(supabase, entities)
  const resolved: MapRow[] = []
  const pending: RequestedEntity[] = []

  for (const entity of entities) {
    const row = stored.get(mapKey(entity.tvdb_id, entity.entity_type))
    if (row && !shouldRetry(row, now)) {
      resolved.push(row)
    } else {
      pending.push(entity)
    }
  }

  const stats = {
    requested: entities.length,
    shows_requested: requestedShowIds.length,
    cache_hits: resolved.length,
    resolved_now: 0,
    not_found: 0,
    ambiguous: 0,
    upstream_calls: 0,
    shows_populated: 0,
    episodes_written: 0,
  }

  const remaining: RequestedEntity[] = []
  const freshRows: MapRow[] = []
  // Cosa TMDB ha risposto per cio' che non si e' risolto: senza, un `ambiguous` e' un vicolo
  // cieco e chi deve risolverlo a mano deve rifare la chiamata per capire perche'.
  const diagnostics: FindDiagnostics[] = []
  let budgetExhausted = false

  // 2. Resolve what is missing, one `/find` per entity — but `FIND_CONCURRENCY` at a time.
  //
  // I risultati si raccolgono per indice e si riordinano alla fine: con le chiamate in parallelo
  // l'ordine di completamento non e' quello della richiesta, e una risposta che cambia ordine a
  // ogni giro e' il genere di cosa che rende un bug irriproducibile.
  const esiti = new Array<{ row: MapRow; find: FindResponse } | undefined>(pending.length)
  /** Chi non e' stato nemmeno tentato: deadline, budget, o una chiamata a monte fallita. */
  const nonTentate = new Set<number>()
  let upstreamRotto = false
  let cursore = 0

  async function risolviUna(index: number): Promise<void> {
    const entity = pending[index]

    // Si ricontrolla qui e non solo nel pool: fra il momento in cui questo worker e' partito e
    // adesso, un altro puo' aver esaurito il budget o visto TMDB cadere.
    if (upstreamRotto || budgetExhausted || Date.now() > deadline) {
      nonTentate.add(index)
      return
    }

    const spend = await spendOne(supabase, callerScope, now, callerLimit)
    if (!spend.allowed) {
      budgetExhausted = true
      nonTentate.add(index)
      return
    }

    try {
      const find = await fetchJson<FindResponse>(
        `${TMDB_API_URL}/find/${entity.tvdb_id}`
          + `?api_key=${TMDB_API_KEY}&external_source=tvdb_id`,
      ) ?? {}
      stats.upstream_calls++
      esiti[index] = { row: resolveFromFind(entity.tvdb_id, entity.entity_type, find, now), find }
    } catch (e) {
      // An unreachable or broken TMDB is not this caller's fault: give the budget back and let
      // the job retry the entity later rather than writing a `not_found` we would then cache.
      console.error(`[catalog-resolve] find(${entity.tvdb_id}) failed: ${e}`)
      await refund(supabase, PROVIDER, spend.scopes)
      upstreamRotto = true
      nonTentate.add(index)
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(FIND_CONCURRENCY, pending.length) }, async () => {
      // Un cursore condiviso invece di fette pre-assegnate: se una entita' e' lenta non blocca
      // un intero blocco, e a budget esaurito i worker si svuotano subito.
      while (true) {
        const index = cursore++
        if (index >= pending.length) return
        await risolviUna(index)
      }
    }),
  )

  for (const [index, entity] of pending.entries()) {
    const esito = esiti[index]
    if (!esito) {
      // Non tentata, o tentata e fallita: in entrambi i casi torna al chiamante, che riprovera'.
      remaining.push(entity)
      continue
    }
    freshRows.push(esito.row)
    resolved.push(esito.row)

    if (esito.row.resolution === 'found') {
      stats.resolved_now++
    } else {
      if (esito.row.resolution === 'not_found') stats.not_found++
      else stats.ambiguous++
      diagnostics.push(
        findDiagnostics(entity.tvdb_id, entity.entity_type, esito.find, esito.row.resolution),
      )
    }
  }

  if (freshRows.length > 0) {
    const { error } = await supabase
      .from('tvdb_tmdb_map')
      .upsert(freshRows, { onConflict: 'tvdb_id,entity_type' })
    if (error) {
      console.error(`[catalog-resolve] map upsert failed: ${error.message}`)
      return jsonResponse({ error: 'write_failed', detail: error.message }, 500)
    }
  }

  // 3. §6, "Ottimizzazione": having resolved a show, pull its episodes in one go. This is what
  //    removes the N+2 TMDB calls per tracking tab and makes the up-next list work offline.
  //
  //    `requestedShowIds` entra qui senza passare dal `populate_episodes`: chi chiede un id TMDB
  //    sta chiedendo esattamente il catalogo di quella serie, e non c'e' un altro risultato che
  //    quella richiesta potrebbe volere.
  if (populateEpisodes || requestedShowIds.length > 0) {
    const showIds = [...new Set([
      ...(populateEpisodes
        ? resolved.filter((r) => r.resolution === 'found' && r.tmdb_show_id !== null)
          .map((r) => r.tmdb_show_id as number)
        : []),
      ...requestedShowIds,
    ])]

    for (const showId of await filterShowsNeedingRefresh(supabase, showIds, now)) {
      if (Date.now() > deadline || budgetExhausted) break

      const outcome = await populateShow(supabase, showId, callerScope, now, callerLimit)
      if (outcome === 'budget') {
        budgetExhausted = true
        break
      }
      if (outcome === 'error') continue
      stats.shows_populated++
      stats.episodes_written += outcome
    }
  }

  return jsonResponse({
    resolved,
    remaining,
    diagnostics,
    budget_exhausted: budgetExhausted,
    stats,
  }, 200)
})

// ---------------------------------------------------------------------------- input

function normalizeEntities(raw: RequestedEntity[] | undefined): RequestedEntity[] | null {
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_ENTITIES_PER_REQUEST) {
    return null
  }

  const seen = new Set<string>()
  const entities: RequestedEntity[] = []
  for (const item of raw) {
    const tvdbId = Number(item?.tvdb_id)
    const entityType = item?.entity_type
    if (!Number.isSafeInteger(tvdbId) || tvdbId <= 0) return null
    if (!ENTITY_TYPES.includes(entityType)) return null

    const key = mapKey(tvdbId, entityType)
    if (seen.has(key)) continue
    seen.add(key)
    entities.push({ tvdb_id: tvdbId, entity_type: entityType })
  }
  return entities.length > 0 ? entities : null
}

const mapKey = (tvdbId: number, entityType: EntityType) => `${tvdbId}:${entityType}`

// ------------------------------------------------------------------------- database

async function readStoredRows(
  supabase: ReturnType<typeof adminClient>,
  entities: RequestedEntity[],
): Promise<Map<string, MapRow>> {
  const { data, error } = await supabase
    .from('tvdb_tmdb_map')
    .select('*')
    .in('tvdb_id', entities.map((e) => e.tvdb_id))

  if (error) {
    // Reading the shared map is not supposed to fail; treating it as "no cache" would re-resolve
    // everything and hide the problem behind a bigger TMDB bill.
    console.error(`[catalog-resolve] map read failed: ${error.message}`)
    return new Map()
  }

  const wanted = new Set(entities.map((e) => mapKey(e.tvdb_id, e.entity_type)))
  const rows = new Map<string, MapRow>()
  for (const row of (data ?? []) as MapRow[]) {
    const key = mapKey(row.tvdb_id, row.entity_type)
    if (wanted.has(key)) rows.set(key, row)
  }
  return rows
}

/** Shows we have never seen, or whose TTL has expired. */
async function filterShowsNeedingRefresh(
  supabase: ReturnType<typeof adminClient>,
  showIds: number[],
  now: Date,
): Promise<number[]> {
  if (showIds.length === 0) return []

  const { data, error } = await supabase
    .from('tmdb_shows')
    .select('tmdb_show_id, next_refresh_at')
    .in('tmdb_show_id', showIds)

  if (error) {
    console.error(`[catalog-resolve] shows read failed: ${error.message}`)
    return []
  }

  const fresh = new Set(
    (data ?? [])
      .filter((row) => new Date(row.next_refresh_at as string).getTime() > now.getTime())
      .map((row) => row.tmdb_show_id as number),
  )
  return showIds.filter((id) => !fresh.has(id))
}

/**
 * Writes one show and its episodes. Returns the number of episodes written, 'budget' when the
 * allowance ran out, or 'error' when TMDB or the database refused.
 */
async function populateShow(
  supabase: ReturnType<typeof adminClient>,
  showId: number,
  callerScope: string,
  now: Date,
  callerLimit: number,
): Promise<number | 'budget' | 'error'> {
  // One call carries both the show and up to 20 of its seasons: `append_to_response` is what makes
  // this 1 request instead of 1 + N, and it is the single reason the tracking tab stops doing N+2
  // TMDB calls per open. Season 0 is asked for too — specials are marked, not filtered (§1.3).
  //
  // How many seasons exist is only known after the first answer, so the first call asks for the
  // first 20 and only a longer-running show needs another.
  const first = await fetchShowChunk(supabase, showId, callerScope, now, callerLimit, initialSeasonChunk())
  if (first === 'budget' || first === 'error') return first

  const show = first.show
  const seasons = first.seasons

  for (const chunk of seasonAppendChunks(seasonRange(show).slice(SEASONS_PER_APPEND))) {
    const next = await fetchShowChunk(supabase, showId, callerScope, now, callerLimit, chunk)
    if (next === 'budget' || next === 'error') break   // keep what we have; the rest next pass
    seasons.push(...next.seasons)
  }

  const { error: showError } = await supabase
    .from('tmdb_shows')
    .upsert(showRow(show, now), { onConflict: 'tmdb_show_id' })
  if (showError) {
    console.error(`[catalog-resolve] show upsert failed: ${showError.message}`)
    return 'error'
  }

  const episodes = episodeRowsFromSeasons(showId, seasons, now)
  if (episodes.length === 0) return 0

  const { error: episodeError } = await supabase
    .from('tmdb_episodes')
    .upsert(episodes, { onConflict: 'tmdb_show_id,season_number,episode_number' })
  if (episodeError) {
    console.error(`[catalog-resolve] episodes upsert failed: ${episodeError.message}`)
    return 'error'
  }
  return episodes.length
}

interface ShowChunk {
  show: ShowPayload & Record<string, unknown>
  seasons: SeasonPayload[]
}

/** One `/tv/{id}` call with a group of seasons appended, budget included. */
async function fetchShowChunk(
  supabase: ReturnType<typeof adminClient>,
  showId: number,
  callerScope: string,
  now: Date,
  callerLimit: number,
  append: string[],
): Promise<ShowChunk | 'budget' | 'error'> {
  const spend = await spendOne(supabase, callerScope, now, callerLimit)
  if (!spend.allowed) return 'budget'

  let payload: (ShowPayload & Record<string, unknown>) | null
  try {
    payload = await fetchJson<ShowPayload & Record<string, unknown>>(
      `${TMDB_API_URL}/tv/${showId}?api_key=${TMDB_API_KEY}&language=en-US`
        + (append.length > 0 ? `&append_to_response=${append.join(',')}` : ''),
    )
  } catch (e) {
    console.error(`[catalog-resolve] tv/${showId} failed: ${e}`)
    await refund(supabase, PROVIDER, spend.scopes)
    return 'error'
  }
  if (!payload?.id) return 'error'

  const seasons: SeasonPayload[] = []
  for (const key of append) {
    const season = payload[key] as SeasonPayload | undefined
    if (season) seasons.push(season)
  }
  return { show: payload, seasons }
}

/**
 * Il `job_id` presentato e' un import vero, di chi chiama, e nella fase che consuma catalogo?
 *
 * Si legge col JWT del chiamante: la policy `import_jobs_select_own` fa da controllo, e un job
 * altrui semplicemente non esiste. E' la stessa forma con cui si e' chiuso l'IDOR di
 * `import-parse` — li' un `user_id` selezionato e mai confrontato lasciava rielaborare l'import
 * di un altro.
 *
 * Un `false` non e' un errore: significa solo "niente budget da import", e la richiesta prosegue
 * col tetto normale. Fallire chiuso, cioe' al tetto piu' basso, e' il verso giusto.
 */
/**
 * La variante per il driver del cron: stesso controllo (job vero, `resolving`, `running`) ma
 * letto da admin, perche' il servizio non ha una RLS che decida per lui. Restituisce il
 * proprietario, che e' l'unica cosa che serve: lo scope del budget si intesta a lui.
 * `null` non e' un errore — significa "niente budget da import", fallire chiuso al tetto
 * piu' basso e' il verso giusto, come per `isImportInCorso`.
 */
async function importJobOwner(
  admin: ReturnType<typeof adminClient>,
  jobId: string | undefined,
): Promise<string | null> {
  if (!jobId) return null

  const { data, error } = await admin
    .from('import_jobs')
    .select('user_id')
    .eq('id', jobId)
    .eq('phase', 'resolving')
    .eq('status', 'running')
    .maybeSingle()

  if (error) {
    console.warn(`[catalog-resolve] verifica del job (driver) fallita, tetto prewarm: ${error.message}`)
    return null
  }
  return data?.user_id ?? null
}

async function isImportInCorso(authHeader: string, jobId: string | undefined): Promise<boolean> {
  if (!jobId) return false

  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  })

  const { data, error } = await caller
    .from('import_jobs')
    .select('id')
    .eq('id', jobId)
    .eq('phase', 'resolving')
    .eq('status', 'running')
    .maybeSingle()

  if (error) {
    console.warn(`[catalog-resolve] verifica del job fallita, si usa il tetto normale: ${error.message}`)
    return false
  }
  return data !== null
}

// --------------------------------------------------------------------------- budget

interface Spend {
  allowed: boolean
  scopes: { scope: string; windowStart: string }[]
}

/**
 * Spends one upstream call against both windows. Per-caller is keyed on the user id rather than
 * the IP: this endpoint requires a JWT, so the identity is real and one account cannot take the
 * whole allowance by changing network.
 */
async function spendOne(
  supabase: ReturnType<typeof adminClient>,
  callerScope: string,
  now: Date,
  callerLimit: number,
): Promise<Spend> {
  // Lo scope arriva dal chiamante e non si deduce dal tetto: se import, uso interattivo e
  // riscaldamento condividessero un contatore, il primo si mangerebbe gli altri e l'app
  // resterebbe senza catalogo per un'ora proprio mentre l'utente guarda l'import scorrere.
  const callerWindow = floorToHour(now)
  const globalWindow = floorToDay(now)

  const callerAllowed = await trySpend(
    supabase, PROVIDER, callerScope, callerWindow, callerLimit,
  )
  if (!callerAllowed) return { allowed: false, scopes: [] }

  const globalAllowed = await trySpend(
    supabase, PROVIDER, 'global', globalWindow, GLOBAL_CALLS_PER_DAY,
  )
  if (!globalAllowed) {
    console.warn(`[catalog-resolve] global daily budget (${GLOBAL_CALLS_PER_DAY}) reached`)
    // Give the caller unit back: it was not spent upstream.
    await refund(supabase, PROVIDER, [{ scope: callerScope, windowStart: callerWindow }])
    return { allowed: false, scopes: [] }
  }

  return {
    allowed: true,
    scopes: [
      { scope: callerScope, windowStart: callerWindow },
      { scope: 'global', windowStart: globalWindow },
    ],
  }
}

// ------------------------------------------------------------------------- upstream

async function fetchJson<T>(url: string): Promise<T | null> {
  const response = await fetch(url)
  if (response.status === 404) return null            // TMDB says: nothing under this id
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${(await response.text()).slice(0, 200)}`)
  }
  return await response.json() as T
}
