import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import {
  applyImportedTimezone,
  type TimezonePreference,
  type TimezonePreferenceStore,
} from './profile.ts'

class StubTimezoneStore implements TimezonePreferenceStore {
  reads: TimezonePreference[] = []
  insertResult = true
  updateResult = true
  readCalls = 0
  insertCalls = 0
  updateCalls = 0

  async read(): Promise<TimezonePreference> {
    this.readCalls += 1
    return this.reads.shift() ?? { exists: false, timezone: null }
  }

  async insertIfAbsent(): Promise<boolean> {
    this.insertCalls += 1
    return this.insertResult
  }

  async updateIfUnset(): Promise<boolean> {
    this.updateCalls += 1
    return this.updateResult
  }
}

Deno.test('timezone importato: non sovrascrive una preferenza esplicita', async () => {
  const store = new StubTimezoneStore()
  store.reads = [{ exists: true, timezone: 'Europe/Paris' }]

  const result = await applyImportedTimezone('Europe/Rome', 'user-1', store)

  assertEquals(result, 'gia_impostato')
  assertEquals(store.insertCalls, 0)
  assertEquals(store.updateCalls, 0)
})

Deno.test('timezone importato: una update che perde la corsa non viene dichiarata applicata', async () => {
  const store = new StubTimezoneStore()
  store.reads = [{ exists: true, timezone: null }]
  store.updateResult = false

  const result = await applyImportedTimezone('Europe/Rome', 'user-1', store)

  assertEquals(result, 'gia_impostato')
  assertEquals(store.updateCalls, 1)
})

Deno.test('timezone importato: una insert concorrente viene riletta senza sovrascrivere', async () => {
  const store = new StubTimezoneStore()
  store.reads = [
    { exists: false, timezone: null },
    { exists: true, timezone: 'America/New_York' },
  ]
  store.insertResult = false

  const result = await applyImportedTimezone('Europe/Rome', 'user-1', store)

  assertEquals(result, 'gia_impostato')
  assertEquals(store.readCalls, 2)
  assertEquals(store.updateCalls, 0)
})

Deno.test('timezone importato: crea una preferenza assente e dichiara il dato mancante', async () => {
  const store = new StubTimezoneStore()
  store.reads = [{ exists: false, timezone: null }]

  assertEquals(await applyImportedTimezone('Europe/Rome', 'user-1', store), 'applicato')
  assertEquals(store.insertCalls, 1)

  const untouched = new StubTimezoneStore()
  assertEquals(await applyImportedTimezone(null, 'user-1', untouched), 'non_presente')
  assertEquals(untouched.readCalls, 0)
})
