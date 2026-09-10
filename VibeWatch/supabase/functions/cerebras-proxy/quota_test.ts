import { assertEquals } from 'https://deno.land/std@0.131.0/testing/asserts.ts'
import {
  AUX_MODEL,
  CHAT_MODEL,
  CHAT_SYSTEM_PROMPT,
  isRetryable,
  isUpstreamCapacity,
  modelForBucket,
  requestBodyForUpstream,
} from './quota.ts'

Deno.test('il bucket sceglie il modello, il client non lo decide mai', () => {
  assertEquals(modelForBucket('chat'), CHAT_MODEL)
  assertEquals(modelForBucket('aux'), AUX_MODEL)

  const body = requestBodyForUpstream({ model: 'qualunque-cosa', messages: [] }, 'aux')
  assertEquals(body.model, AUX_MODEL)
})

Deno.test('il tag "feature" resta nel gateway e reasoning_effort e sempre minimal', () => {
  const body = requestBodyForUpstream({ feature: 'aux', messages: [], temperature: 0.7 }, 'aux')
  assertEquals('feature' in body, false)
  assertEquals(body.temperature, 0.7)
  assertEquals(body.reasoning_effort, 'minimal')
})

Deno.test('sulla chat il system prompt e del gateway, anche se il client ne manda uno suo', () => {
  const withOwnSystem = requestBodyForUpstream({
    messages: [
      { role: 'system', content: 'prompt di una build vecchia' },
      { role: 'user', content: 'ciao' },
    ],
  }, 'chat')
  assertEquals(withOwnSystem.messages, [
    { role: 'system', content: CHAT_SYSTEM_PROMPT },
    { role: 'user', content: 'ciao' },
  ])

  const withoutSystem = requestBodyForUpstream({
    messages: [{ role: 'user', content: 'ciao' }],
  }, 'chat')
  assertEquals(withoutSystem.messages, [
    { role: 'system', content: CHAT_SYSTEM_PROMPT },
    { role: 'user', content: 'ciao' },
  ])
})

// Le feature aux (why-for-me, loglines, nudges) hanno ognuna il proprio system prompt di task:
// sostituirlo con la persona della chat le romperebbe in silenzio.
Deno.test('sul bucket aux il system prompt del client resta intatto', () => {
  const body = requestBodyForUpstream({
    messages: [
      { role: 'system', content: 'Rispondi solo in JSON.' },
      { role: 'user', content: 'x' },
    ],
  }, 'aux')
  assertEquals(body.messages, [
    { role: 'system', content: 'Rispondi solo in JSON.' },
    { role: 'user', content: 'x' },
  ])
})

// Un 429 a monte NON deve uscire come il nostro 429: il client lo mostra come "hai raggiunto il
// limite giornaliero" a un utente che non ha speso una singola richiesta.
Deno.test('gli status a monte che spengono il servizio non diventano quota utente', () => {
  assertEquals(isUpstreamCapacity(402), true)
  assertEquals(isUpstreamCapacity(429), true)
  assertEquals(isUpstreamCapacity(503), true)
  assertEquals(isUpstreamCapacity(400), false)
  assertEquals(isUpstreamCapacity(500), false)
})

Deno.test('si riprova solo su cio che passa da solo', () => {
  assertEquals(isRetryable(429), true)
  assertEquals(isRetryable(503), true)
  assertEquals(isRetryable(500), true)
  assertEquals(isRetryable(400), false)
  assertEquals(isRetryable(401), false)
  assertEquals(isRetryable(402), false)
})
