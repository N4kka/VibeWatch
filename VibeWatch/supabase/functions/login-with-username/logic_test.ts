import { assertEquals, assertMatch, assertNotEquals } from 'https://deno.land/std@0.131.0/testing/asserts.ts'
import { decoyEmail, normalizeUsername, parseLoginRequest } from './logic.ts'

Deno.test('la normalizzazione corregge battitura, non intenzioni', () => {
  assertEquals(normalizeUsername('  Nakka  '), 'nakka')
  assertEquals(normalizeUsername('NAKKA'), 'nakka')
  assertEquals(normalizeUsername('nakka'), 'nakka')
})

Deno.test("cio' che non ha la forma di uno username e' null", () => {
  assertEquals(normalizeUsername('ab'), null)
  assertEquals(normalizeUsername('a'.repeat(21)), null)
  assertEquals(normalizeUsername('mario.rossi'), null)
  assertEquals(normalizeUsername('mario rossi'), null)
  assertEquals(normalizeUsername('utente@email.com'), null,
    "un input con la chiocciola non e' uno username: il client manda qui solo i non-email, ma la funzione non si fida")
  assertEquals(normalizeUsername(42), null)
  assertEquals(normalizeUsername(null), null)
})

Deno.test("una richiesta senza campi e' malformata, non una credenziale sbagliata", () => {
  assertEquals(parseLoginRequest({}), null)
  assertEquals(parseLoginRequest({ username: 'nakka' }), null)
  assertEquals(parseLoginRequest({ password: 'x' }), null)
  assertEquals(parseLoginRequest({ username: 'nakka', password: '' }), null)
  assertEquals(parseLoginRequest({ username: 'nakka', password: 'x'.repeat(513) }), null)
  assertEquals(parseLoginRequest('non un oggetto'), null)
  assertEquals(parseLoginRequest(null), null)
})

Deno.test("uno username fuori forma e' una credenziale sbagliata, non una richiesta malformata", () => {
  // `invalid_request` puo' dire "manca un campo" senza dire niente sugli utenti; tutto cio' che
  // riguarda il contenuto delle credenziali deve rispondere in un modo solo.
  assertEquals(parseLoginRequest({ username: 'ab', password: 'segreta' }), 'invalid_credentials')
  assertEquals(parseLoginRequest({ username: 'user@mail.com', password: 'segreta' }), 'invalid_credentials')
})

Deno.test('una richiesta valida si normalizza', () => {
  assertEquals(parseLoginRequest({ username: '  NAKKA ', password: 'segreta' }),
    { username: 'nakka', password: 'segreta' })
})

Deno.test("l'email esca non puo' esistere e non si ripete", () => {
  const a = decoyEmail()
  const b = decoyEmail()
  assertMatch(a, /^no-such-user-[0-9a-f-]{36}@login\.invalid$/,
    "'.invalid' e' il TLD riservato di RFC 2606: non risolve per costruzione")
  assertNotEquals(a, b, "un valore fisso permetterebbe di riconoscere l'esca dai log di GoTrue")
})
