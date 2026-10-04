import { assertEquals } from 'https://deno.land/std@0.168.0/testing/asserts.ts'
import { countryReleaseDays } from './releaseDate.ts'

const payload = {
  results: [
    { iso_3166_1: 'US', release_dates: [{ release_date: '2026-09-02T00:00:00.000Z', type: 4 }] },
    {
      iso_3166_1: 'IT',
      release_dates: [
        { release_date: '2026-08-30T00:00:00.000Z', type: 1 },
        { release_date: '2026-09-24T00:00:00.000Z', type: 3 },
        { release_date: '2026-04-23T00:00:00.000Z', type: 3 },
      ],
    },
  ],
}

Deno.test('every non-premiere day for the country, sorted', () => {
  // The postponed 04-23 stays listed: the radar's window, not this function, keeps it quiet.
  assertEquals(countryReleaseDays(payload, 'IT'), ['2026-04-23', '2026-09-24'])
})

Deno.test('empty when the country has no dates', () => {
  assertEquals(countryReleaseDays(payload, 'FR'), [])
  assertEquals(countryReleaseDays(undefined, 'IT'), [])
})
