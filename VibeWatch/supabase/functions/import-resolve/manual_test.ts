import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import {
  manualContextForPending,
  manualEpisodeDisposition,
  manualContextFromCheckpoint,
  manualContextsFromCheckpoint,
  planEpisodeResolutionBatch,
} from './manual.ts'

const JOB = '7d70f2b0-531c-4ef5-a5e9-95d102fea1dc'
const context = {
  job_id: JOB,
  tvdb_series_id: 79824,
  tmdb_show_id: 1399,
}

Deno.test('manual checkpoint is accepted only for the current job and positive ids', () => {
  assertEquals(manualContextFromCheckpoint({ manual_episode_context: context }, JOB), context)
  assertEquals(manualContextFromCheckpoint({ manual_episode_context: context }, 'other-job'), null)
  assertEquals(manualContextFromCheckpoint({ manual_episode_context: {
    ...context, tmdb_show_id: 0,
  } }, JOB), null)
  assertEquals(manualContextFromCheckpoint({}, JOB), null)
})

Deno.test('manual batch keeps valid current-job contexts and selects the pending series', () => {
  const second = { job_id: JOB, tvdb_series_id: 121361, tmdb_show_id: 1402 }
  const contexts = manualContextsFromCheckpoint({ manual_episode_contexts: [
    context,
    { ...context, job_id: 'other-job', tvdb_series_id: 99 },
    second,
  ] }, JOB)

  assertEquals(contexts, [context, second])
  assertEquals(manualContextForPending(contexts, [
    { row_index: 1, raw: { tvdb_series_id: 121361, tvdb_episode_id: 201 } },
  ]), second)
  assertEquals(manualContextForPending(contexts, [
    { row_index: 2, raw: { tvdb_series_id: 999, tvdb_episode_id: 202 } },
  ]), null)
})

Deno.test('manual batch reader remains compatible with the legacy singular checkpoint', () => {
  assertEquals(manualContextsFromCheckpoint({ manual_episode_context: context }, JOB), [context])
})

Deno.test('manual batch retries unresolved maps, keeps found identity and defers beyond limit', () => {
  const pending = [101, 102, 103, 104].map((episodeId, index) => ({
    row_index: index,
    raw: {
      row_kind: 'event',
      tvdb_series_id: 79824,
      tvdb_episode_id: episodeId,
      season_number: 99,
      episode_number: 99,
    },
  }))
  const known = new Map([
    [101, { tvdb_id: 101, resolution: 'not_found', tmdb_show_id: null }],
    [102, { tvdb_id: 102, resolution: 'ambiguous', tmdb_show_id: null }],
    [103, { tvdb_id: 103, resolution: 'found', tmdb_show_id: 1399 }],
  ])

  const plan = planEpisodeResolutionBatch(pending, known, context, 2)

  assertEquals(plan.requestedEpisodeIds, [101, 102])
  assertEquals(plan.manualContext, context)
  assertEquals(plan.deferredEpisodeIds, [104])
  // The planner never reads or returns the export's 99/99 coordinates.
  assertEquals(Object.keys(plan).includes('season_number'), false)
})

Deno.test('normal batch requests only missing maps and has no manual context', () => {
  const pending = [
    { row_index: 1, raw: { row_kind: 'event', tvdb_episode_id: 1 } },
    { row_index: 2, raw: { row_kind: 'event', tvdb_episode_id: 2 } },
  ]
  const known = new Map([
    [1, { tvdb_id: 1, resolution: 'not_found', tmdb_show_id: null }],
  ])

  const plan = planEpisodeResolutionBatch(pending, known, null, 50)

  assertEquals(plan.requestedEpisodeIds, [2])
  assertEquals(plan.manualContext, null)
  assertEquals(plan.deferredEpisodeIds, [])
})

Deno.test('manual disposition waits for the attempted batch and rejects another show', () => {
  const unresolved = { tvdb_id: 1, resolution: 'ambiguous', tmdb_show_id: null }
  assertEquals(manualEpisodeDisposition(unresolved, 1399, false), 'pending')
  assertEquals(manualEpisodeDisposition(unresolved, 1399, true), 'unresolved')
  assertEquals(manualEpisodeDisposition({
    tvdb_id: 1, resolution: 'found', tmdb_show_id: 1399,
  }, 1399, false), 'resolved')
  assertEquals(manualEpisodeDisposition({
    tvdb_id: 1, resolution: 'found', tmdb_show_id: 10,
  }, 1399, true), 'conflict')
})
