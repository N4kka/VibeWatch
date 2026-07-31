// Pure logic of `catalog-resolve` (SPEC v3 §6), separated from I/O so it can be tested without a
// database or a TMDB key: `deno test supabase/functions/catalog-resolve/`.
//
// The rule this file exists to enforce: **never infer a match from season/episode numbers**. TVDB
// and TMDB number differently — the oracle shows 31 series out of 430 disagreeing, and the worst
// cases (Digimon 253 episode ids collapsing onto 107 numbers, One-Punch Man 36 vs 44) are exactly
// absolute vs per-season numbering. Everything here resolves by `tvdb_id` alone and takes the
// numbers from TMDB's answer.

export type EntityType = 'series' | 'episode' | 'movie'
export type Resolution = 'found' | 'not_found' | 'ambiguous'

/** A row of `tvdb_tmdb_map`. */
export interface MapRow {
  tvdb_id: number
  entity_type: EntityType
  tmdb_show_id: number | null
  tmdb_movie_id: number | null
  season_number: number | null
  episode_number: number | null
  resolution: Resolution
  method: string
  resolved_at: string
}

/** The shape of `GET /find/{id}?external_source=tvdb_id` that we care about. */
export interface FindResponse {
  tv_results?: { id: number }[]
  tv_episode_results?: { id: number; show_id: number; season_number: number; episode_number: number }[]
  movie_results?: { id: number }[]
  tv_season_results?: { id: number }[]
  person_results?: { id: number }[]
}

/**
 * What TMDB actually returned, per bucket, plus the ids of the matching one.
 *
 * Returned to the caller for anything that did not resolve. §6 says an `ambiguous` row is
 * "da risolvere a mano": whoever does that needs to see WHY it was ambiguous, and going back to
 * TMDB by hand to find out is exactly the friction that leaves those rows unresolved forever.
 */
export interface FindDiagnostics {
  tvdb_id: number
  entity_type: EntityType
  resolution: Resolution
  counts: Record<string, number>
  matching_ids: number[]
}

export function findDiagnostics(
  tvdbId: number,
  entityType: EntityType,
  find: FindResponse,
  resolution: Resolution,
): FindDiagnostics {
  const tv = find.tv_results ?? []
  const episodes = find.tv_episode_results ?? []
  const movies = find.movie_results ?? []
  const matching = entityType === 'series' ? tv : entityType === 'episode' ? episodes : movies

  return {
    tvdb_id: tvdbId,
    entity_type: entityType,
    resolution,
    counts: {
      tv: tv.length,
      tv_episode: episodes.length,
      movie: movies.length,
      tv_season: (find.tv_season_results ?? []).length,
      person: (find.person_results ?? []).length,
    },
    matching_ids: matching.map((r) => r.id),
  }
}

export interface ShowPayload {
  id: number
  name?: string
  first_air_date?: string | null
  last_air_date?: string | null
  status?: string | null
  in_production?: boolean | null
  number_of_seasons?: number | null
  number_of_episodes?: number | null
  poster_path?: string | null
  origin_country?: string[] | null
  episode_run_time?: number[] | null
}

export interface SeasonPayload {
  season_number?: number
  episodes?: {
    id?: number
    episode_number?: number
    season_number?: number
    name?: string | null
    air_date?: string | null
    runtime?: number | null
    still_path?: string | null
  }[]
}

export interface EpisodeRow {
  tmdb_show_id: number
  season_number: number
  episode_number: number
  tmdb_episode_id: number | null
  name: string | null
  air_date: string | null
  runtime_minutes: number | null
  still_path: string | null
  refreshed_at: string
}

/** §6.3: a `not_found` is not retried for 30 days — no point hammering TMDB for absent content. */
export const NOT_FOUND_RETRY_DAYS = 30

/** A finished series does not change again; a returning one does. §3.1, "TTL differenziato". */
export const REFRESH_DAYS_ENDED = 90
export const REFRESH_DAYS_RUNNING = 7

/** TMDB caps `append_to_response` at 20 items, so seasons are fetched in groups of 20. */
export const SEASONS_PER_APPEND = 20

/**
 * Maps a `/find` answer onto a `tvdb_tmdb_map` row.
 *
 * A TVDB id is only unique within its own entity space, so the same number can be both a series
 * and an episode on TMDB — and in practice it very often is. Game of Thrones (tvdb 121361) comes
 * back as `tv: 1, tv_episode: 1`.
 *
 * So the rule is: **only the bucket matching the requested `entity_type` decides.** One hit there
 * resolves it; zero or several make it `ambiguous`. A hit in another bucket is ignored — asking
 * for a series and getting exactly one series is not an ambiguity, and treating it as one would
 * have sent most of a real import to the manual pile.
 *
 * What must never happen is resolving from the wrong bucket: that is how an import silently
 * attributes someone's viewing history to a different show. The bucket is chosen by the caller's
 * `entity_type`, which comes from the export's own structure, never guessed from the numbers.
 */
export function resolveFromFind(
  tvdbId: number,
  entityType: EntityType,
  find: FindResponse,
  now: Date,
): MapRow {
  const base = {
    tvdb_id: tvdbId,
    entity_type: entityType,
    tmdb_show_id: null,
    tmdb_movie_id: null,
    season_number: null,
    episode_number: null,
    resolved_at: now.toISOString(),
  }

  const tv = find.tv_results ?? []
  const episodes = find.tv_episode_results ?? []
  const movies = find.movie_results ?? []

  if (tv.length === 0 && episodes.length === 0 && movies.length === 0) {
    return { ...base, resolution: 'not_found', method: 'tmdb_find' }
  }

  const matching = entityType === 'series' ? tv : entityType === 'episode' ? episodes : movies

  // Zero or several hits in our own bucket: not decidable here, it needs a human (§6).
  if (matching.length !== 1) {
    return { ...base, resolution: 'ambiguous', method: 'tmdb_find' }
  }

  if (entityType === 'series') {
    return { ...base, resolution: 'found', method: 'tmdb_find', tmdb_show_id: tv[0].id }
  }

  if (entityType === 'movie') {
    return { ...base, resolution: 'found', method: 'tmdb_find', tmdb_movie_id: movies[0].id }
  }

  const episode = episodes[0]
  return {
    ...base,
    resolution: 'found',
    method: 'tmdb_find',
    tmdb_show_id: episode.show_id,
    // Straight from TMDB. The numbers in the TV Time export are TVDB's and are NOT interchangeable.
    season_number: episode.season_number,
    episode_number: episode.episode_number,
  }
}

/** True when a stored row is worth asking TMDB about again. */
export function shouldRetry(row: Pick<MapRow, 'resolution' | 'resolved_at'>, now: Date): boolean {
  if (row.resolution === 'found') return false
  if (row.resolution === 'ambiguous') return false   // needs a human, not another identical call
  const age = now.getTime() - new Date(row.resolved_at).getTime()
  return age >= NOT_FOUND_RETRY_DAYS * 24 * 60 * 60 * 1000
}

/** When to look at this show again. */
export function nextRefreshAt(show: ShowPayload, now: Date): Date {
  const finished = !show.in_production
    && (show.status === 'Ended' || show.status === 'Canceled')
  const days = finished ? REFRESH_DAYS_ENDED : REFRESH_DAYS_RUNNING
  return new Date(now.getTime() + days * 24 * 60 * 60 * 1000)
}

/** A `tmdb_shows` row from a `/tv/{id}` payload. */
export function showRow(show: ShowPayload, now: Date) {
  return {
    tmdb_show_id: show.id,
    name: show.name ?? '',
    first_air_date: emptyToNull(show.first_air_date),
    last_air_date: emptyToNull(show.last_air_date),
    status: show.status ?? null,
    in_production: show.in_production ?? null,
    number_of_seasons: show.number_of_seasons ?? null,
    number_of_episodes: show.number_of_episodes ?? null,
    poster_path: show.poster_path ?? null,
    origin_country: show.origin_country ?? null,
    episode_run_time: show.episode_run_time ?? null,
    refreshed_at: now.toISOString(),
    next_refresh_at: nextRefreshAt(show, now).toISOString(),
  }
}

/**
 * Flattens the `season/N` payloads of an `append_to_response` into `tmdb_episodes` rows.
 *
 * Specials (season 0) are kept: §1.3 marks them, it does not filter them. Whether they count
 * towards progress is decided later, in one place.
 */
export function episodeRowsFromSeasons(
  tmdbShowId: number,
  seasons: SeasonPayload[],
  now: Date,
): EpisodeRow[] {
  const rows: EpisodeRow[] = []
  const seen = new Set<string>()

  for (const season of seasons) {
    for (const episode of season.episodes ?? []) {
      const seasonNumber = episode.season_number ?? season.season_number
      const episodeNumber = episode.episode_number
      if (seasonNumber === undefined || seasonNumber === null) continue
      if (episodeNumber === undefined || episodeNumber === null) continue

      // The primary key is (show, season, episode): a duplicate in the payload would make the
      // whole upsert fail with "affects row a second time", taking the good rows down with it.
      const key = `${seasonNumber}:${episodeNumber}`
      if (seen.has(key)) continue
      seen.add(key)

      rows.push({
        tmdb_show_id: tmdbShowId,
        season_number: seasonNumber,
        episode_number: episodeNumber,
        tmdb_episode_id: episode.id ?? null,
        name: episode.name ?? null,
        air_date: emptyToNull(episode.air_date),
        runtime_minutes: episode.runtime ?? null,
        still_path: episode.still_path ?? null,
        refreshed_at: now.toISOString(),
      })
    }
  }
  return rows
}

/**
 * Every season number a show has, specials included: 0 .. number_of_seasons.
 *
 * Season 0 is asked for unconditionally. TMDB does not report whether a show has specials in
 * `number_of_seasons`, and a missing `season/0` in the answer costs nothing.
 */
export function seasonRange(show: ShowPayload): number[] {
  const count = Math.max(0, show.number_of_seasons ?? 0)
  return Array.from({ length: count + 1 }, (_, index) => index)
}

/**
 * The seasons to ask for before knowing how many there are: the first group, which covers every
 * show with at most 19 seasons plus its specials — that is nearly all of them.
 */
export function initialSeasonChunk(): string[] {
  return Array.from({ length: SEASONS_PER_APPEND }, (_, index) => `season/${index}`)
}

/** Season numbers to request, in groups TMDB will accept. Season 0 is included when present. */
export function seasonAppendChunks(seasonNumbers: number[]): string[][] {
  const chunks: string[][] = []
  for (let i = 0; i < seasonNumbers.length; i += SEASONS_PER_APPEND) {
    chunks.push(seasonNumbers.slice(i, i + SEASONS_PER_APPEND).map((n) => `season/${n}`))
  }
  return chunks
}

/**
 * Gli id TMDB di serie da riscaldare direttamente, ripuliti.
 *
 * **Perche' esiste un ingresso che non passa da TVDB.** Tutta la funzione e' costruita attorno a
 * §1.5, cioe' "gli id dell'export TV Time sono di TheTVDB e vanno risolti". Chi usa VibeWatch da
 * prima non ha mai visto un id TVDB: le sue serie sono gia' identificate per `tmdb_show_id`, e per
 * loro il passaggio da `/find` non e' solo inutile, e' impossibile. Senza questo ingresso la
 * migrazione dello storico (blocco 7) produrrebbe card senza nome e senza prossimo episodio,
 * perche' `tmdb_shows`/`tmdb_episodes` per quelle serie non li popola nessuno.
 *
 * Stesso tetto di `entities`: il lavoro per id e' lo stesso — una `/tv/{id}` con le stagioni in
 * append — e un tetto diverso sarebbe solo una seconda cosa da ricordarsi.
 */
export function normalizeShowIds(raw: unknown, max: number): number[] | null {
  if (raw === undefined || raw === null) return []
  if (!Array.isArray(raw) || raw.length > max) return null

  const ids: number[] = []
  const seen = new Set<number>()
  for (const item of raw) {
    const id = Number(item)
    if (!Number.isSafeInteger(id) || id <= 0) return null
    if (seen.has(id)) continue
    seen.add(id)
    ids.push(id)
  }
  return ids
}

/** TMDB sends "" for a missing date; a `date` column will not take that. */
function emptyToNull(value: string | null | undefined): string | null {
  const trimmed = (value ?? '').trim()
  return trimmed.length > 0 ? trimmed : null
}
