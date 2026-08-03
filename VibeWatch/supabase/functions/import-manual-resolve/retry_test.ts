import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { buildManualRetryPlan, normalizeManualResolutions } from './retry.ts'

const event = (rowIndex: number, episodeId: unknown, error = 'catalogo: ambiguous') => ({
  row_index: rowIndex,
  raw: {
    row_kind: 'event',
    tvdb_series_id: 79824,
    tvdb_episode_id: episodeId,
    season_number: 99,
    episode_number: 99,
  },
  resolved: null,
  status: 'unresolved',
  error,
})

Deno.test('manual retry reopens only catalog-unresolved rows and ignores export numbering', () => {
  const plan = buildManualRetryPlan([
    event(1, 101),
    event(2, 0),
    { row_index: 3, raw: { row_kind: 'status', tvdb_series_id: 79824 },
      resolved: null, status: 'unresolved', error: 'catalogo: not_found' },
    { row_index: 4, raw: { row_kind: 'favorite', tvdb_series_id: 79824 },
      resolved: null, status: 'unresolved', error: 'catalogo: ambiguous' },
    { row_index: 5, raw: { row_kind: 'event', tvdb_series_id: 79824, tvdb_episode_id: 102 },
      resolved: null, status: 'skipped', error: 'scrittura: senza_dedup_key' },
  ], [], {
    unresolved: 1,
    statuses_unresolved: 1,
    favorites_unresolved: 1,
  })

  assertEquals(plan.episodeIds, [101])
  assertEquals(plan.counts, { events: 1, statuses: 1, favorites: 1, ratings: 0 })
  assertEquals(plan.rows.map((row) => row.row_index), [1, 3, 4])
  assertEquals(plan.rows.every((row) => row.status === 'pending' && row.resolved === null), true)
  assertEquals(plan.rows[0].raw.season_number, 99)
  assertEquals(plan.rows[0].resolved, null, '99/99 resta raw e non diventa mai identità risolta')
})

Deno.test('manual retry reopens only unresolved ratings belonging to selected episode ids', () => {
  const ratings = [
    { row_index: 10, raw: { row_kind: 'rating', tvdb_episode_id: 101 },
      resolved: null, status: 'skipped', error: 'voti: non_risolto' },
    { row_index: 11, raw: { row_kind: 'rating', tvdb_episode_id: 999 },
      resolved: null, status: 'skipped', error: 'voti: non_risolto' },
    { row_index: 12, raw: { row_kind: 'rating', tvdb_episode_id: 101 },
      resolved: null, status: 'skipped', error: 'voti: voto_gia_in_app' },
  ]

  const plan = buildManualRetryPlan([event(1, 101)], ratings, {
    unresolved: 1, ratings_not_written: 1,
  })

  assertEquals(plan.rows.map((row) => row.row_index), [1, 10])
  assertEquals(plan.counts.ratings, 1)
  assertEquals(plan.adjustedTotals.unresolved, 0)
  assertEquals(plan.adjustedTotals.ratings_not_written, 0)
})

Deno.test('manual retry never reopens a rating already mapped to another show', () => {
  const ratings = [
    { row_index: 10, raw: { row_kind: 'rating', tvdb_episode_id: 101 },
      resolved: null, status: 'skipped', error: 'voti: non_risolto' },
  ]
  const plan = buildManualRetryPlan(
    [event(1, 101, 'catalogo: conflitto_serie')],
    ratings,
    { unresolved: 1, ratings_not_written: 1 },
    new Set([101]),
  )

  assertEquals(plan.rows.map((row) => row.row_index), [1])
  assertEquals(plan.counts.ratings, 0)
  assertEquals(plan.adjustedTotals.ratings_not_written, 1)
})

Deno.test('manual retry total adjustments never go below zero', () => {
  const plan = buildManualRetryPlan([
    event(1, 101),
    { row_index: 3, raw: { row_kind: 'status', tvdb_series_id: 79824 },
      resolved: null, status: 'unresolved', error: 'catalogo: not_found' },
  ], [], { unresolved: 0, statuses_unresolved: 0 })

  assertEquals(plan.adjustedTotals.unresolved, 0)
  assertEquals(plan.adjustedTotals.statuses_unresolved, 0)
})

Deno.test('manual resolutions normalize one non-empty batch with unique series', () => {
  assertEquals(normalizeManualResolutions([
    { tvdb_series_id: '79824', tmdb_show_id: 1399 },
    { tvdb_series_id: 121361, tmdb_show_id: '1402' },
  ]), [
    { tvdbSeriesId: 79824, tmdbShowId: 1399 },
    { tvdbSeriesId: 121361, tmdbShowId: 1402 },
  ])
  assertEquals(normalizeManualResolutions([]), null)
  assertEquals(normalizeManualResolutions([
    { tvdb_series_id: 79824, tmdb_show_id: 1399 },
    { tvdb_series_id: 79824, tmdb_show_id: 1402 },
  ]), null)
  assertEquals(normalizeManualResolutions([
    { tvdb_series_id: 79824, tmdb_show_id: 0 },
  ]), null)
})
