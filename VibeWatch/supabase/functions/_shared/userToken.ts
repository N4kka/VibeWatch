// Chi sta chiamando, a partire dal suo JWT.
//
// `auth.getUser(token)` non verifica soltanto il token. GoTrue controlla firma e scadenza e POI
// cerca la riga di `auth.sessions` indicata dal claim `session_id`: se non la trova risponde
// 403 `session_not_found`. È un controllo che nessun altro pezzo dell'API fa — PostgREST guarda
// firma e scadenza e basta — e la differenza si vedeva addosso all'utente.
//
// Il caso vero, dai log del 25 agosto. `POST /auth/v1/logout` ha per default `scope=global` e
// cancella TUTTE le sessioni dell'account: un logout dal web portava via anche quella del
// telefono, che però restava con un access token buono fino a un'ora. Liste, voti, sync
// continuavano a funzionare (passano da PostgREST), e le uniche due cose che si rompevano erano
// `catalog-resolve` e `cerebras-proxy`, cioè le due che passano di qui. Sul telefono voleva dire
// che "vista tutta" rispondeva `Supabase HTTP 401: {"error":"invalid_token"}` per un'ora, senza
// che niente invitasse a rifare l'accesso.
//
// Arrivare a `session_not_found` PROVA che il token è autentico e non scaduto: GoTrue guarda la
// sessione dopo, non prima. Quindi in quel caso il `sub` vale esattamente quanto vale per
// PostgREST — che è ciò che regge tutto il resto dell'app — e si usa. Ogni altro fallimento
// (firma sbagliata, token scaduto, GoTrue irraggiungibile) resta un rifiuto.

/** La forma che serve dell'errore di `getUser`: supabase-js ne riempie almeno uno dei tre. */
export interface AuthErrorLike {
  code?: string | null
  status?: number | null
  message?: string | null
}

/** La forma che serve del client: tenerla minima è ciò che rende testabile il resto. */
export interface UserLookup {
  auth: {
    getUser(token: string): Promise<{
      data: { user: { id: string } | null } | null
      error: AuthErrorLike | null
    }>
  }
}

/** La sessione non c'è più, ma di per sé il token è stato accettato. */
export function isSessionNotFound(error: AuthErrorLike | null | undefined): boolean {
  if (!error) return false
  if (error.code === 'session_not_found') return true
  return error.status === 403 &&
    (error.message ?? '').toLowerCase().includes('session not found')
}

/**
 * Il `sub` di un JWT che qualcun altro ha già verificato.
 *
 * Qui NON si verifica la firma — non si può, la chiave sta in GoTrue — e per questo la funzione
 * si chiama solo dopo un `session_not_found`, che è la prova che la verifica è già avvenuta.
 * Scadenza e ruolo si ricontrollano lo stesso: costano niente e rendono impossibile che un
 * cambio di comportamento a monte trasformi questa funzione in una porta aperta.
 */
export function subjectFromVerifiedJWT(token: string, nowSeconds: number): string | null {
  const parts = token.split('.')
  if (parts.length !== 3) return null

  let payload: Record<string, unknown>
  try {
    payload = JSON.parse(decodeSegment(parts[1])) as Record<string, unknown>
  } catch {
    return null
  }

  const sub = payload.sub
  if (typeof sub !== 'string' || sub.length === 0) return null
  if (payload.role !== 'authenticated') return null

  const exp = payload.exp
  if (typeof exp !== 'number' || !Number.isFinite(exp) || exp <= nowSeconds) return null

  return sub
}

function decodeSegment(segment: string): string {
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/')
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=')
  const binary = atob(padded)
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0))
  return new TextDecoder().decode(bytes)
}

/**
 * L'id dell'utente che presenta `token`, o `null` se il token non vale.
 *
 * `now` è iniettabile per i test; in produzione è l'orologio.
 */
export async function authenticatedUserId(
  supabase: UserLookup,
  token: string,
  now: () => number = Date.now,
): Promise<string | null> {
  const { data, error } = await supabase.auth.getUser(token)
  if (!error && data?.user?.id) return data.user.id
  if (isSessionNotFound(error)) {
    return subjectFromVerifiedJWT(token, Math.floor(now() / 1000))
  }
  return null
}
