// La parte pura di login-with-username: cosa e' una richiesta valida, e come si risponde a cio'
// che non lo e'. Unit-tested: `deno test supabase/functions/login-with-username/`.

/// La stessa forma del CHECK su `profiles` e di `UsernameRules.pattern` nel client.
export const USERNAME_PATTERN = /^[a-z0-9_]{3,20}$/

/// Minuscole e spazi ai bordi sono errori di battitura; il resto no. Un input che dopo la
/// normalizzazione non ha la forma di uno username e' `null` — e per il chiamante esterno deve
/// essere indistinguibile da uno username che non esiste.
export function normalizeUsername(raw: unknown): string | null {
  if (typeof raw !== 'string') return null
  const normalized = raw.trim().toLowerCase()
  return USERNAME_PATTERN.test(normalized) ? normalized : null
}

export interface LoginRequest {
  username: string
  password: string
}

/// `null` = richiesta malformata (400 `invalid_request`): manca un campo, o non sono stringhe.
/// Uno username fuori forma NON e' malformazione: e' una credenziale sbagliata, e la distinzione
/// conta perche' `invalid_request` puo' dire "ti sei dimenticato un campo" senza dire niente
/// sugli utenti, mentre tutto cio' che riguarda il *contenuto* delle credenziali risponde in un
/// modo solo.
export function parseLoginRequest(body: unknown): LoginRequest | 'invalid_credentials' | null {
  if (typeof body !== 'object' || body === null) return null
  const b = body as Record<string, unknown>
  if (typeof b.username !== 'string' || typeof b.password !== 'string') return null
  if (b.password.length === 0 || b.password.length > 512) return null

  const username = normalizeUsername(b.username)
  if (username === null) return 'invalid_credentials'
  return { username, password: b.password }
}

/// L'email finta per uno username che non esiste. Il giro verso GoTrue si fa comunque, cosi'
/// "utente inesistente" e "password sbagliata" costano lo stesso tempo: senza, la differenza di
/// latenza direbbe quali username esistono. `.invalid` e' il TLD riservato (RFC 2606): non puo'
/// risolversi per costruzione.
export function decoyEmail(): string {
  return `no-such-user-${crypto.randomUUID()}@login.invalid`
}

/// L'unica risposta per ogni fallimento di credenziali: username inesistente, fuori forma,
/// password sbagliata. Un attaccante che le distingue ha un oracolo sugli username.
export const INVALID_CREDENTIALS = { error: 'invalid_credentials' } as const
