// Login con username (SPEC v3 §3.7).
//
// **Perche' esiste.** `signIn` con username richiede di risolvere username -> email, e ogni via
// client-side e' indifendibile: una RPC che restituisce l'email dato lo username e' un endpoint
// di raccolta indirizzi, e `public_profiles` esclude l'email apposta. Qui la risoluzione e
// l'autenticazione sono **atomiche**: l'email non lascia mai il server senza la password giusta.
//
// **Le tre difese, e perche' ognuna c'e':**
// 1. ogni fallimento di credenziali risponde `invalid_credentials`, identico: distinguere
//    "username inesistente" da "password sbagliata" sarebbe un oracolo sugli username;
// 2. per uno username inesistente il giro verso GoTrue si fa comunque, con un'email esca su TLD
//    `.invalid` — senza, la latenza direbbe quali username esistono;
// 3. tetto per IP via `api_proxy_try_spend` (provider `auth_login`): GoTrue da qui vede l'IP
//    della funzione, non del client, quindi il suo rate limiting sul brute force non basta piu'.
//
// verify_jwt e' SPENTO al deploy (`--no-verify-jwt`): il chiamante non ha ancora una sessione,
// e' il login. `hasSupabaseKey` resta come chiudi-porta, come per youtube-search.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import {
  adminClient,
  callerKey,
  floorToHour,
  hasSupabaseKey,
  jsonResponse,
} from '../_shared/proxy.ts'
import { decoyEmail, INVALID_CREDENTIALS, parseLoginRequest } from './logic.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

// 30 tentativi l'ora per IP: larghissimo per una persona (il login riuscito e' uno), stretto per
// un dizionario. Fallisce chiuso: se il contatore non risponde, non si tenta il login.
const LOGIN_ATTEMPTS_PER_HOUR = 30

async function trySpendLogin(req: Request): Promise<boolean> {
  const supabase = adminClient()
  const { data, error } = await supabase.rpc('api_proxy_try_spend', {
    p_provider: 'auth_login',
    p_scope: callerKey(req),
    p_window_start: floorToHour(new Date()),
    p_limit: LOGIN_ATTEMPTS_PER_HOUR,
  })
  if (error) {
    console.error(`[login-with-username] budget check failed, refusing: ${error.message}`)
    return false
  }
  return data === true
}

serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405)
  }
  if (!hasSupabaseKey(req)) {
    return jsonResponse({ error: 'missing_api_key' }, 401)
  }

  let body: unknown
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'invalid_request' }, 400)
  }

  const parsed = parseLoginRequest(body)
  if (parsed === null) {
    return jsonResponse({ error: 'invalid_request' }, 400)
  }

  if (!(await trySpendLogin(req))) {
    return jsonResponse({ error: 'too_many_attempts' }, 429)
  }

  if (parsed === 'invalid_credentials') {
    // Uno username fuori forma non esiste per definizione, ma la risposta e' la stessa di una
    // password sbagliata — e si paga comunque il tentativo nel budget, come tutti.
    return jsonResponse(INVALID_CREDENTIALS, 400)
  }

  // La risoluzione, con la chiave di servizio: profiles ha la RLS chiusa apposta. Il profilo
  // deve essere vivo; niente altro filtro — anche un profilo privato puo' fare login.
  const supabase = adminClient()
  const { data: rows, error } = await supabase
    .from('profiles')
    .select('email')
    .eq('username', parsed.username)
    .is('deleted_at', null)
    .limit(1)
  if (error) {
    console.error(`[login-with-username] lookup failed: ${error.message}`)
    return jsonResponse({ error: 'internal_error' }, 500)
  }

  const email: string = rows?.[0]?.email ?? decoyEmail()

  const grant = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SUPABASE_ANON_KEY,
    },
    body: JSON.stringify({ email, password: parsed.password }),
  })

  if (!grant.ok) {
    // Qualunque cosa GoTrue abbia detto (email inesistente, password sbagliata, utente
    // disabilitato): da fuori e' una sola risposta.
    return jsonResponse(INVALID_CREDENTIALS, 400)
  }

  // La sessione di GoTrue, cosi' com'e': access_token, refresh_token, user. L'email dentro
  // `user` e' quella del chiamante autenticato — a quel punto e' sua.
  const session = await grant.text()
  return new Response(session, {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
})
