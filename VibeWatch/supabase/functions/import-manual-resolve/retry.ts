// Pure retry planning for SPEC v3 §7.4. This module deliberately has no episode matching logic:
// it only moves catalog failures back into the existing exact-TVDB resolving pipeline.

export interface RetryStagingRow {
  row_index: number
  raw: Record<string, unknown>
  resolved: Record<string, unknown> | null
  status: string
  error: string | null
}

export interface PendingRetryRow {
  row_index: number
  raw: Record<string, unknown>
  resolved: null
  status: 'pending'
  error: null
}

export interface ManualRetryPlan {
  rows: PendingRetryRow[]
  episodeIds: number[]
  counts: { events: number; statuses: number; favorites: number; ratings: number }
  adjustedTotals: Record<string, unknown>
}

const positiveInt = (value: unknown): number | null => {
  const number = Number(value)
  return Number.isSafeInteger(number) && number > 0 ? number : null
}

const pendingCopy = (row: RetryStagingRow): PendingRetryRow => ({
  row_index: row.row_index,
  raw: row.raw,
  resolved: null,
  status: 'pending',
  error: null,
})

export function buildManualRetryPlan(
  seriesRows: RetryStagingRow[],
  ratingRows: RetryStagingRow[],
  totals: Record<string, unknown>,
  conflictingRatingEpisodeIds: ReadonlySet<number> = new Set<number>(),
): ManualRetryPlan {
  const rows: PendingRetryRow[] = []
  const episodeIds: number[] = []
  const episodeSet = new Set<number>()
  const counts = { events: 0, statuses: 0, favorites: 0, ratings: 0 }

  for (const row of seriesRows) {
    if (row.status !== 'unresolved' || !row.error?.startsWith('catalogo:')) continue
    const kind = String(row.raw.row_kind ?? '')
    if (kind === 'event') {
      const episodeId = positiveInt(row.raw.tvdb_episode_id)
      if (episodeId === null) continue
      if (!episodeSet.has(episodeId)) {
        episodeSet.add(episodeId)
        episodeIds.push(episodeId)
      }
      counts.events++
    } else if (kind === 'status') {
      counts.statuses++
    } else if (kind === 'favorite') {
      counts.favorites++
    } else {
      continue
    }
    rows.push(pendingCopy(row))
  }

  for (const row of ratingRows) {
    if (row.status !== 'skipped' || row.error !== 'voti: non_risolto') continue
    const episodeId = positiveInt(row.raw.tvdb_episode_id)
    if (episodeId === null || !episodeSet.has(episodeId)) continue
    // Una mappa `found` è immutabile. Se punta a un'altra serie, l'evento resterà in conflitto
    // e il voto non deve tornare pending: import-write lo assocerebbe a quella serie sbagliata.
    if (conflictingRatingEpisodeIds.has(episodeId)) continue
    rows.push(pendingCopy(row))
    counts.ratings++
  }

  const adjustedTotals = { ...totals }
  const subtract = (key: string, amount: number) => {
    const current = Number(adjustedTotals[key])
    adjustedTotals[key] = Math.max(0, (Number.isFinite(current) ? current : 0) - amount)
  }
  subtract('unresolved', counts.events)
  subtract('statuses_unresolved', counts.statuses)
  subtract('favorites_unresolved', counts.favorites)
  subtract('ratings_not_written', counts.ratings)

  return { rows, episodeIds, counts, adjustedTotals }
}
