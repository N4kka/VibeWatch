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
  resolveFromFind,
  SEASONS_PER_APPEND,
  seasonAppendChunks,
  SeasonPayload,
  seasonRange,
  shouldRetry,
  showRow,
  ShowPayload,
} from './resolution.ts'

const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY') ?? ''
const TMDB_API_URL = 'https://api.themoviedb.org/3'
const PROVIDER = 'tmdb'

// §7.2: the import resolves in batches of 50.
const MAX_ENTITIES_PER_REQUEST = 50

// Budgets. TMDB does not publish a daily cap, so these exist to bound a runaway client loop, not
// to ration a scarce quota: an import of 430 series is ~430 find calls plus a handful per series
// for the episodes, and must not be throttled into uselessness.
const CALLER_CALLS_PER_HOUR = 600
const GLOBAL_CALLS_PER_DAY = 50_000

// Stop starting new upstream calls after this. An Edge Function has a hard wall-clock limit, and
// being killed mid-batch would lose the rows resolved so far.
const DEADLINE_MS = 20_000

interface RequestedEntity {
  tvdb_id: number
  entity_type: EntityType
}

interface Body {
  entities?: RequestedEntity[]
  /** Set false to resolve ids without pulling the episode catalog (cheaper, for a first pass). */
  populate_episodes?: boolean
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
  const { data: userResult, error: userError } = await supabase.auth.getUser(
    authHeader.slice('Bearer '.length),
  )
  if (userError || !userResult?.user) {
    return jsonResponse({ error: 'invalid_token' }, 401)
  }
  const userId = userResult.user.id

  let body: Body
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400)
  }

  const entities = normalizeEntities(body.entities)
  if (entities === null) {
    return jsonResponse({ error: 'entities must be [{tvdb_id, entity_type}], 1-50 items' }, 400)
  }

  const populateEpisodes = body.populate_episodes !== false
  const now = new Date()
  const deadline = Date.now() + DEADLINE_MS

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

  // 2. Resolve what is missing, one `/find` per entity.
  for (const [index, entity] of pending.entries()) {
    if (Date.now() > deadline || budgetExhausted) {
      remaining.push(...pending.slice(index))
      break
    }

    const spend = await spendOne(supabase, userId, now)
    if (!spend.allowed) {
      budgetExhausted = true
      remaining.push(...pending.slice(index))
      break
    }

    let find: FindResponse | null
    try {
      find = await fetchJson<FindResponse>(
        `${TMDB_API_URL}/find/${entity.tvdb_id}`
          + `?api_key=${TMDB_API_KEY}&external_source=tvdb_id`,
      )
    } catch (e) {
      // An unreachable or broken TMDB is not this caller's fault: give the budget back and let
      // the job retry the entity later rather than writing a `not_found` we would then cache.
      console.error(`[catalog-resolve] find(${entity.tvdb_id}) failed: ${e}`)
      await refund(supabase, PROVIDER, spend.scopes)
      remaining.push(...pending.slice(index))
      break
    }

    stats.upstream_calls++
    const row = resolveFromFind(entity.tvdb_id, entity.entity_type, find ?? {}, now)
    freshRows.push(row)
    resolved.push(row)

    if (row.resolution === 'found') {
      stats.resolved_now++
    } else {
      if (row.resolution === 'not_found') stats.not_found++
      else stats.ambiguous++
      diagnostics.push(findDiagnostics(entity.tvdb_id, entity.entity_type, find ?? {}, row.resolution))
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
  if (populateEpisodes) {
    const showIds = [...new Set(
      resolved.filter((r) => r.resolution === 'found' && r.tmdb_show_id !== null)
        .map((r) => r.tmdb_show_id as number),
    )]

    for (const showId of await filterShowsNeedingRefresh(supabase, showIds, now)) {
      if (Date.now() > deadline || budgetExhausted) break

      const outcome = await populateShow(supabase, showId, userId, now)
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
  userId: string,
  now: Date,
): Promise<number | 'budget' | 'error'> {
  // One call carries both the show and up to 20 of its seasons: `append_to_response` is what makes
  // this 1 request instead of 1 + N, and it is the single reason the tracking tab stops doing N+2
  // TMDB calls per open. Season 0 is asked for too — specials are marked, not filtered (§1.3).
  //
  // How many seasons exist is only known after the first answer, so the first call asks for the
  // first 20 and only a longer-running show needs another.
  const first = await fetchShowChunk(supabase, showId, userId, now, initialSeasonChunk())
  if (first === 'budget' || first === 'error') return first

  const show = first.show
  const seasons = first.seasons

  for (const chunk of seasonAppendChunks(seasonRange(show).slice(SEASONS_PER_APPEND))) {
    const next = await fetchShowChunk(supabase, showId, userId, now, chunk)
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
  userId: string,
  now: Date,
  append: string[],
): Promise<ShowChunk | 'budget' | 'error'> {
  const spend = await spendOne(supabase, userId, now)
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
  userId: string,
  now: Date,
): Promise<Spend> {
  const callerScope = `user:${userId}`
  const callerWindow = floorToHour(now)
  const globalWindow = floorToDay(now)

  const callerAllowed = await trySpend(
    supabase, PROVIDER, callerScope, callerWindow, CALLER_CALLS_PER_HOUR,
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
