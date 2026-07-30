// Unit tests for the pure part of `catalog-resolve` (SPEC v3 §6).
//
// Run: deno test supabase/functions/catalog-resolve/
//
// These cover the decisions that would fail silently in production: attributing an episode to the
// wrong show, caching a "not found" forever, refreshing a finished series every week, or losing
// specials on the way into the catalog.

import {
  assert,
  assertEquals,
  assertFalse,
} from 'https://deno.land/std@0.224.0/assert/mod.ts'
import {
  episodeRowsFromSeasons,
  initialSeasonChunk,
  NOT_FOUND_RETRY_DAYS,
  REFRESH_DAYS_ENDED,
  REFRESH_DAYS_RUNNING,
  resolveFromFind,
  SEASONS_PER_APPEND,
  seasonAppendChunks,
  seasonRange,
  shouldRetry,
  showRow,
} from './resolution.ts'

const NOW = new Date('2026-07-30T12:00:00.000Z')
const daysAgo = (days: number) =>
  new Date(NOW.getTime() - days * 24 * 60 * 60 * 1000).toISOString()

// ------------------------------------------------------------------ resolveFromFind

Deno.test('a series id resolves to a TMDB show', () => {
  const row = resolveFromFind(79824, 'series', { tv_results: [{ id: 1399 }] }, NOW)

  assertEquals(row.resolution, 'found')
  assertEquals(row.tmdb_show_id, 1399)
  assertEquals(row.method, 'tmdb_find')
  assertEquals(row.season_number, null)
})

Deno.test('an episode takes its numbers from TMDB, never from the export', () => {
  // The TV Time export calls this one S1E17 (absolute numbering); TMDB says S2E5. The stored row
  // must say S2E5, otherwise the import writes the viewing history onto the wrong episode.
  const row = resolveFromFind(335156, 'episode', {
    tv_episode_results: [{ id: 63056, show_id: 1399, season_number: 2, episode_number: 5 }],
  }, NOW)

  assertEquals(row.resolution, 'found')
  assertEquals(row.tmdb_show_id, 1399)
  assertEquals(row.season_number, 2)
  assertEquals(row.episode_number, 5)
})

Deno.test('a movie id resolves to a TMDB movie', () => {
  const row = resolveFromFind(603, 'movie', { movie_results: [{ id: 603 }] }, NOW)

  assertEquals(row.resolution, 'found')
  assertEquals(row.tmdb_movie_id, 603)
  assertEquals(row.tmdb_show_id, null)
})

Deno.test('nothing anywhere is not_found', () => {
  const row = resolveFromFind(999999, 'series', {}, NOW)

  assertEquals(row.resolution, 'not_found')
  assertEquals(row.tmdb_show_id, null)
})

Deno.test('two shows under one id is ambiguous, not a guess', () => {
  const row = resolveFromFind(123, 'series', { tv_results: [{ id: 1 }, { id: 2 }] }, NOW)

  assertEquals(row.resolution, 'ambiguous')
  assertEquals(row.tmdb_show_id, null)
})

Deno.test('an id that also means something else is ambiguous', () => {
  // TVDB numbers series and episodes in separate spaces, so the same number can be both. Picking
  // one is how someone's history ends up on an unrelated show.
  const row = resolveFromFind(4711, 'series', {
    tv_results: [{ id: 1399 }],
    tv_episode_results: [{ id: 63056, show_id: 66732, season_number: 1, episode_number: 1 }],
  }, NOW)

  assertEquals(row.resolution, 'ambiguous')
})

Deno.test('a hit in the wrong bucket does not resolve the entity', () => {
  // Asked for an episode, TMDB knows the id only as a series: not decidable here.
  const row = resolveFromFind(4711, 'episode', { tv_results: [{ id: 1399 }] }, NOW)

  assertEquals(row.resolution, 'ambiguous')
  assertEquals(row.season_number, null)
})

// ---------------------------------------------------------------------- shouldRetry

Deno.test('a found row is never re-resolved', () => {
  assertFalse(shouldRetry({ resolution: 'found', resolved_at: daysAgo(400) }, NOW))
})

Deno.test('a not_found is left alone for 30 days, then retried', () => {
  assertFalse(shouldRetry(
    { resolution: 'not_found', resolved_at: daysAgo(NOT_FOUND_RETRY_DAYS - 1) }, NOW,
  ))
  assert(shouldRetry(
    { resolution: 'not_found', resolved_at: daysAgo(NOT_FOUND_RETRY_DAYS + 1) }, NOW,
  ))
})

Deno.test('an ambiguous row waits for a human, not for another identical call', () => {
  assertFalse(shouldRetry({ resolution: 'ambiguous', resolved_at: daysAgo(365) }, NOW))
})

// -------------------------------------------------------------------------- showRow

Deno.test('a finished series is not refreshed weekly', () => {
  const row = showRow(
    { id: 1, name: 'Ended Show', status: 'Ended', in_production: false, number_of_seasons: 5 },
    NOW,
  )
  const days = (new Date(row.next_refresh_at).getTime() - NOW.getTime()) / 86_400_000

  assertEquals(days, REFRESH_DAYS_ENDED)
})

Deno.test('a returning series is refreshed weekly', () => {
  const row = showRow(
    { id: 2, name: 'Returning', status: 'Returning Series', in_production: true },
    NOW,
  )
  const days = (new Date(row.next_refresh_at).getTime() - NOW.getTime()) / 86_400_000

  assertEquals(days, REFRESH_DAYS_RUNNING)
})

Deno.test('a cancelled show still in production keeps the short TTL', () => {
  const row = showRow({ id: 3, name: 'Limbo', status: 'Canceled', in_production: true }, NOW)
  const days = (new Date(row.next_refresh_at).getTime() - NOW.getTime()) / 86_400_000

  assertEquals(days, REFRESH_DAYS_RUNNING)
})

Deno.test('an empty date becomes null, not an empty string', () => {
  // TMDB sends "" for an unknown date and a `date` column will not take it.
  const row = showRow({ id: 4, name: 'No dates', first_air_date: '', last_air_date: undefined }, NOW)

  assertEquals(row.first_air_date, null)
  assertEquals(row.last_air_date, null)
})

// ------------------------------------------------------------ episodeRowsFromSeasons

Deno.test('episodes are flattened with their season number', () => {
  const rows = episodeRowsFromSeasons(1399, [{
    season_number: 1,
    episodes: [
      { id: 63056, episode_number: 1, name: 'Winter Is Coming', air_date: '2011-04-17', runtime: 62 },
      { id: 63057, episode_number: 2, name: 'The Kingsroad', air_date: '2011-04-24', runtime: 56 },
    ],
  }], NOW)

  assertEquals(rows.length, 2)
  assertEquals(rows[0].tmdb_show_id, 1399)
  assertEquals(rows[0].season_number, 1)
  assertEquals(rows[0].episode_number, 1)
  assertEquals(rows[0].runtime_minutes, 62)
  assertEquals(rows[1].tmdb_episode_id, 63057)
})

Deno.test('specials are kept: §1.3 marks them, it does not filter them', () => {
  const rows = episodeRowsFromSeasons(1399, [{
    season_number: 0,
    episodes: [{ id: 1, episode_number: 1, name: 'Special', air_date: '2010-01-01' }],
  }], NOW)

  assertEquals(rows.length, 1)
  assertEquals(rows[0].season_number, 0)
})

Deno.test('an episode with no air date carries null, not an empty string', () => {
  const rows = episodeRowsFromSeasons(1, [{
    season_number: 1,
    episodes: [{ id: 9, episode_number: 1, air_date: '' }],
  }], NOW)

  assertEquals(rows[0].air_date, null)
})

Deno.test('a duplicate episode in the payload is dropped once', () => {
  // The primary key is (show, season, episode). A duplicate would abort the whole upsert with
  // "cannot affect row a second time", taking every good row of the batch down with it.
  const rows = episodeRowsFromSeasons(1, [{
    season_number: 1,
    episodes: [
      { id: 1, episode_number: 1, name: 'first' },
      { id: 2, episode_number: 1, name: 'duplicate' },
    ],
  }], NOW)

  assertEquals(rows.length, 1)
  assertEquals(rows[0].name, 'first')
})

Deno.test('an episode without a number is skipped rather than written as null', () => {
  const rows = episodeRowsFromSeasons(1, [{
    season_number: 1,
    episodes: [{ id: 1, name: 'unnumbered' }, { id: 2, episode_number: 3 }],
  }], NOW)

  assertEquals(rows.length, 1)
  assertEquals(rows[0].episode_number, 3)
})

// ---------------------------------------------------------------------- season math

Deno.test('the season range includes specials', () => {
  assertEquals(seasonRange({ id: 1, number_of_seasons: 3 }), [0, 1, 2, 3])
  assertEquals(seasonRange({ id: 1 }), [0])
})

Deno.test('the first call asks for one full group of seasons', () => {
  const chunk = initialSeasonChunk()

  assertEquals(chunk.length, SEASONS_PER_APPEND)
  assertEquals(chunk[0], 'season/0')
  assertEquals(chunk[SEASONS_PER_APPEND - 1], `season/${SEASONS_PER_APPEND - 1}`)
})

Deno.test('seasons past the first group are chunked, never sent in one oversized call', () => {
  // TMDB caps append_to_response at 20; a long-running show (Pokémon, One Piece) exceeds it.
  const chunks = seasonAppendChunks(seasonRange({ id: 1, number_of_seasons: 45 })
    .slice(SEASONS_PER_APPEND))

  assertEquals(chunks.length, 2)
  assertEquals(chunks[0].length, SEASONS_PER_APPEND)
  assertEquals(chunks[0][0], 'season/20')
  assertEquals(chunks[1].length, 6)
  assertEquals(chunks[1][5], 'season/45')
})

Deno.test('a short show needs no extra call', () => {
  const chunks = seasonAppendChunks(seasonRange({ id: 1, number_of_seasons: 3 })
    .slice(SEASONS_PER_APPEND))

  assertEquals(chunks, [])
})
