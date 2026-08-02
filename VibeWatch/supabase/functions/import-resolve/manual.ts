// Pure planning for SPEC v3 §7.4 manual retries. Keeping this separate from the Edge Function
// makes the checkpoint and batching rules executable without a database or upstream API.

export interface ManualEpisodeContext {
  job_id: string
  tvdb_series_id: number
  tmdb_show_id: number
}

export interface PendingEventRow {
  row_index: number
  raw: Record<string, unknown>
}

export interface KnownEpisodeMap {
  tvdb_id: number
  resolution: string
  tmdb_show_id: number | null
}

export interface EpisodeResolutionPlan {
  requestedEpisodeIds: number[]
  deferredEpisodeIds: number[]
  manualContext: ManualEpisodeContext | null
}

export type ManualEpisodeDisposition = 'pending' | 'resolved' | 'unresolved' | 'conflict'

export function manualEpisodeDisposition(
  map: KnownEpisodeMap | undefined,
  expectedShowId: number,
  attemptedThisTurn: boolean,
): ManualEpisodeDisposition {
  if (!map) return 'pending'
  if (map.resolution === 'found') {
    return map.tmdb_show_id === expectedShowId ? 'resolved' : 'conflict'
  }
  return attemptedThisTurn ? 'unresolved' : 'pending'
}

export function manualContextFromCheckpoint(
  checkpoint: unknown,
  jobId: string,
): ManualEpisodeContext | null {
  if (!checkpoint || typeof checkpoint !== 'object' || Array.isArray(checkpoint)) return null
  const raw = (checkpoint as Record<string, unknown>).manual_episode_context
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const value = raw as Record<string, unknown>
  const contextJobId = String(value.job_id ?? '').trim()
  const tvdbSeriesId = Number(value.tvdb_series_id)
  const tmdbShowId = Number(value.tmdb_show_id)
  if (contextJobId === '' || contextJobId !== jobId) return null
  if (!Number.isSafeInteger(tvdbSeriesId) || tvdbSeriesId <= 0) return null
  if (!Number.isSafeInteger(tmdbShowId) || tmdbShowId <= 0) return null
  return { job_id: contextJobId, tvdb_series_id: tvdbSeriesId, tmdb_show_id: tmdbShowId }
}

export function planEpisodeResolutionBatch(
  pending: PendingEventRow[],
  known: Map<number, KnownEpisodeMap>,
  manualContext: ManualEpisodeContext | null,
  limit: number,
): EpisodeResolutionPlan {
  const ids: number[] = []
  const seen = new Set<number>()
  for (const row of pending) {
    if (manualContext && Number(row.raw.tvdb_series_id) !== manualContext.tvdb_series_id) continue
    const id = Number(row.raw.tvdb_episode_id)
    if (!Number.isSafeInteger(id) || id <= 0 || seen.has(id)) continue
    seen.add(id)
    const stored = known.get(id)
    const needsRequest = manualContext ? stored?.resolution !== 'found' : stored === undefined
    if (needsRequest) ids.push(id)
  }

  const safeLimit = Number.isSafeInteger(limit) && limit > 0 ? limit : 1
  return {
    requestedEpisodeIds: ids.slice(0, safeLimit),
    deferredEpisodeIds: ids.slice(safeLimit),
    manualContext,
  }
}
