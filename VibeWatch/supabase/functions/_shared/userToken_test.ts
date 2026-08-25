import { assertEquals } from 'https://deno.land/std@0.208.0/assert/mod.ts'
import {
  authenticatedUserId,
  AuthErrorLike,
  isSessionNotFound,
  subjectFromVerifiedJWT,
  UserLookup,
} from './userToken.ts'

const NOW_SECONDS = 1_787_680_000
const NOW_MS = NOW_SECONDS * 1000
const USER = '9b339294-6f14-49a6-b977-693213ae89fb'

function base64url(text: string): string {
  const bytes = new TextEncoder().encode(text)
  const binary = Array.from(bytes, (b) => String.fromCharCode(b)).join('')
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function jwt(payload: Record<string, unknown>): string {
  const segment = (value: unknown) => base64url(JSON.stringify(value))
  return `${segment({ alg: 'HS256', typ: 'JWT' })}.${segment(payload)}.firma-non-verificata-qui`
}

/** Il token del caso reale: valido, non scaduto, sessione cancellata da un logout altrove. */
const validToken = jwt({
  sub: USER,
  role: 'authenticated',
  exp: NOW_SECONDS + 3600,
  session_id: '462ed1f0-6385-4d86-a594-0dffa4cd22fe',
})

function lookup(result: {
  user?: { id: string } | null
  error?: AuthErrorLike | null
}): UserLookup {
  return {
    auth: {
      getUser: () =>
        Promise.resolve({
          data: { user: result.user ?? null },
          error: result.error ?? null,
        }),
    },
  }
}

const sessionNotFound: AuthErrorLike = {
  code: 'session_not_found',
  status: 403,
  message: 'Session not found',
}

Deno.test('un token buono passa da getUser e basta', async () => {
  const userId = await authenticatedUserId(lookup({ user: { id: USER } }), validToken, () => NOW_MS)
  assertEquals(userId, USER)
})

// Il caso che rompeva "vista tutta": access token integro, sessione cancellata da un logout
// globale su un altro device. GoTrue dice `session_not_found` DOPO aver verificato firma e
// scadenza, quindi il token è autentico quanto lo è per PostgREST — che è ciò che serve il resto
// dell'app senza fare storie.
Deno.test('sessione sparita ma token valido: si accetta il sub', async () => {
  const userId = await authenticatedUserId(
    lookup({ error: sessionNotFound }),
    validToken,
    () => NOW_MS,
  )
  assertEquals(userId, USER)
})

Deno.test('session_not_found si riconosce anche dal solo messaggio', () => {
  assertEquals(isSessionNotFound({ status: 403, message: 'Session not found' }), true)
  assertEquals(isSessionNotFound({ code: 'session_not_found' }), true)
  assertEquals(isSessionNotFound({ status: 403, message: 'Forbidden' }), false)
  assertEquals(isSessionNotFound({ status: 401, message: 'invalid JWT' }), false)
  assertEquals(isSessionNotFound(null), false)
})

// La ragione per cui la scorciatoia è stretta: qualsiasi altro rifiuto resta un rifiuto, e in
// particolare un token scaduto non entra dalla finestra.
Deno.test('un token scaduto non passa nemmeno con session_not_found', async () => {
  const scaduto = jwt({ sub: USER, role: 'authenticated', exp: NOW_SECONDS - 1 })
  const userId = await authenticatedUserId(
    lookup({ error: sessionNotFound }),
    scaduto,
    () => NOW_MS,
  )
  assertEquals(userId, null)
})

Deno.test('un errore diverso da session_not_found non apre niente', async () => {
  const userId = await authenticatedUserId(
    lookup({ error: { status: 401, message: 'invalid JWT: signature is invalid' } }),
    validToken,
    () => NOW_MS,
  )
  assertEquals(userId, null)
})

Deno.test('un GoTrue irraggiungibile (5xx) non è un lasciapassare', async () => {
  const userId = await authenticatedUserId(
    lookup({ error: { status: 503, message: 'service unavailable' } }),
    validToken,
    () => NOW_MS,
  )
  assertEquals(userId, null)
})

Deno.test('subjectFromVerifiedJWT rifiuta ciò che non è un token utente', () => {
  assertEquals(subjectFromVerifiedJWT('non-un-jwt', NOW_SECONDS), null)
  assertEquals(subjectFromVerifiedJWT('a.b', NOW_SECONDS), null)
  assertEquals(subjectFromVerifiedJWT(`a.${btoa('non json')}.c`, NOW_SECONDS), null)
  // Il ruolo conta: la chiave anonima o di servizio non è un utente.
  assertEquals(
    subjectFromVerifiedJWT(jwt({ sub: USER, role: 'service_role', exp: NOW_SECONDS + 60 }), NOW_SECONDS),
    null,
  )
  // Senza scadenza non si sa fino a quando vale: no.
  assertEquals(
    subjectFromVerifiedJWT(jwt({ sub: USER, role: 'authenticated' }), NOW_SECONDS),
    null,
  )
  assertEquals(
    subjectFromVerifiedJWT(jwt({ role: 'authenticated', exp: NOW_SECONDS + 60 }), NOW_SECONDS),
    null,
  )
})

// I `sub` sono uuid ASCII, ma il payload GoTrue porta anche `user_metadata` con nomi veri:
// un base64url decodificato byte per byte spezzerebbe gli accenti e il JSON.parse morirebbe.
Deno.test('il payload si decodifica come UTF-8, non come latin1', () => {
  const token = jwt({
    sub: USER,
    role: 'authenticated',
    exp: NOW_SECONDS + 60,
    user_metadata: { full_name: 'Niccolò Sarli — «prova»' },
  })
  assertEquals(subjectFromVerifiedJWT(token, NOW_SECONDS), USER)
})
