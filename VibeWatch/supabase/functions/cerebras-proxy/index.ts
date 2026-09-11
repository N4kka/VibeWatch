import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { SignJWT, importPKCS8 } from 'https://esm.sh/jose@v5.2.3'
import {
  GLOBAL_DAILY_TOKEN_BUDGET,
  QuotaBucket,
  bucketForRequest,
  dailyLimitForTier,
  hasReachedDailyLimit,
  isRetryable,
  isUpstreamCapacity,
  parseRequestBody,
  requestBodyForUpstream,
  usageCountForToday,
  usageDayKey,
} from './quota.ts'
import { withCors } from '../_shared/cors.ts'
import { fetchIsProFromRevenueCat } from '../_shared/revenuecat.ts'
import { authenticatedUserId } from '../_shared/userToken.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
// Client-facing (low-priv) key: prefer new publishable key, fall back to legacy anon.
const SUPABASE_ANON_KEY = (() => {
  const s = Deno.env.get('SUPABASE_PUBLISHABLE_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_ANON_KEY') ?? ''
})()
// Admin (RLS-bypassing) key: prefer new secret key, fall back to legacy service_role.
const SUPABASE_SERVICE_ROLE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()
// Vertex AI, endpoint OpenAI-compatibile. Auth con OAuth token da service account, NON con
// una API key: e' lo stesso meccanismo che process-notifications usa per FCM.
// La location e' "global" apposta — evita di legare la capacita' a una singola regione.
const VERTEX_SERVICE_ACCOUNT = Deno.env.get('VERTEX_SERVICE_ACCOUNT') ?? ''
const VERTEX_PROJECT_ID = Deno.env.get('VERTEX_PROJECT_ID') ?? ''
const VERTEX_ENDPOINT =
  `https://aiplatform.googleapis.com/v1beta1/projects/${VERTEX_PROJECT_ID}` +
  '/locations/global/endpoints/openapi/chat/completions'

// RevenueCat REST API: fonte autorevole dello stato Pro.
// NB: il client puo forgiare user_daily_quota.is_pro (RLS owner-scoped), quindi quel
// valore NON e affidabile per il gating. Verifichiamo direttamente con RevenueCat.
// L'app_user_id RevenueCat coincide con l'auth uid Supabase (AuthService.syncRevenueCatUser).
const REVENUECAT_API_KEY = Deno.env.get('REVENUECAT_API_KEY') ?? ''
const PRO_ENTITLEMENT_ID = Deno.env.get('PRO_ENTITLEMENT_ID') ?? 'StartingVibe Pro'
const PRO_CACHE_TTL_MS = 5 * 60 * 1000

// Cache a livello di istanza (persiste tra richieste su un'istanza "calda")
// per evitare una chiamata RevenueCat ad ogni richiesta AI.
const proStatusCache = new Map<string, { isPro: boolean; expiresAt: number }>()

type SupabaseAdminClient = any

// Il token OAuth vale un'ora: su un'istanza calda si riusa invece di firmare un JWT nuovo a
// ogni richiesta. Cinque minuti di margine per non usarne uno scaduto in volo.
let cachedAccessToken: { token: string; expiresAt: number } | null = null

async function vertexAccessToken(): Promise<string> {
  const now = Date.now()
  if (cachedAccessToken && cachedAccessToken.expiresAt > now) {
    return cachedAccessToken.token
  }

  const serviceAccount = JSON.parse(VERTEX_SERVICE_ACCOUNT)
  const privateKey = await importPKCS8(serviceAccount.private_key.replace(/\\n/g, '\n'), 'RS256')

  const jwt = await new SignJWT({
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    aud: 'https://oauth2.googleapis.com/token',
    scope: 'https://www.googleapis.com/auth/cloud-platform',
  })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuedAt()
    .setExpirationTime('1h')
    .sign(privateKey)

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  })

  if (!response.ok) {
    throw new Error(`Vertex token request failed: ${response.status} ${await response.text()}`)
  }

  const data = await response.json()
  cachedAccessToken = { token: data.access_token, expiresAt: now + 55 * 60 * 1000 }
  return data.access_token
}

// Due tentativi in piu, brevi: 429/503/5xx a monte sono quasi sempre picchi di capacita' che
// passano in un paio di secondi. Le attese restano corte apposta — dall'altra parte c'e' un
// utente fermo sullo spinner, e un backoff lungo su un upstream che fallisce lento sfonda il
// timeout del client invece di salvarlo.
const RETRY_DELAYS_MS = [1000, 3000]

async function callVertex(body: string): Promise<Response> {
  const accessToken = await vertexAccessToken()

  for (let attempt = 0; ; attempt++) {
    const response = await fetch(VERTEX_ENDPOINT, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body,
    })

    if (response.ok || !isRetryable(response.status) || attempt >= RETRY_DELAYS_MS.length) {
      return response
    }

    console.warn(`Vertex ${response.status}, retry ${attempt + 1}/${RETRY_DELAYS_MS.length}`)
    await new Promise((resolve) => setTimeout(resolve, RETRY_DELAYS_MS[attempt]))
  }
}

function jsonResponse(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

// Verifica lo stato Pro interrogando RevenueCat (autorevole), con cache breve.
// La lookup prova entrambe le grafie dell'app_user_id (vedi _shared/revenuecat.ts:
// iOS registra l'uuid in maiuscolo, qui arriva minuscolo dal JWT).
// In caso di errore/secret mancante NON si ricade sul DB forgiabile: si usa l'ultimo
// stato noto in cache (se presente) o, in assenza, il tier Free (default sicuro).
async function isProUser(userId: string): Promise<boolean> {
  const now = Date.now()
  const cached = proStatusCache.get(userId)
  if (cached && cached.expiresAt > now) {
    return cached.isPro
  }

  const lookup = await fetchIsProFromRevenueCat(userId, REVENUECAT_API_KEY, PRO_ENTITLEMENT_ID)
  if (lookup === null) {
    console.warn('Stato Pro indeterminato; uso ultimo stato noto / Free')
    return cached?.isPro ?? false
  }

  proStatusCache.set(userId, { isPro: lookup, expiresAt: now + PRO_CACHE_TTL_MS })
  return lookup
}

async function requestsUsedToday(
  adminSupabase: SupabaseAdminClient,
  userId: string,
  todayKey: string,
  bucket: QuotaBucket,
): Promise<number> {
  try {
    // Filtrare per usage_date e' essenziale: la PK e' (user_id, usage_date), quindi un utente ha
    // una riga per giorno e un .limit(1) senza filtro puo' pescare la riga di ieri (conteggio 0).
    const { data, error } = await adminSupabase
      .from('user_ai_token_usage')
      .select('request_count, aux_request_count, usage_date, last_updated')
      .eq('user_id', userId)
      .eq('usage_date', todayKey)
      .limit(1)

    if (error) {
      console.warn('Failed to read AI request usage:', error.message)
      return 0
    }

    return usageCountForToday(data?.[0] ?? null, todayKey, bucket)
  } catch (error) {
    console.warn('Failed to read AI request usage:', error)
  }

  if (bucket === 'chat') {
    try {
      const { data, error } = await adminSupabase.rpc('get_ai_token_usage', {
        p_user_id: userId,
      })
      if (!error && typeof data === 'number') {
        return data
      }
    } catch (_) {
      // Ignore: quota should fail open if both tracking paths are unavailable.
    }
  }

  return 0
}

async function recordSuccessfulRequest(
  adminSupabase: SupabaseAdminClient,
  userId: string,
  bucket: QuotaBucket,
) {
  // Single writer for the daily request counters: the log_ai_request_usage RPC increments the
  // bucket's column atomically on (user_id, usage_date), so it needs no read-modify-write.
  try {
    const { error } = await adminSupabase.rpc('log_ai_request_usage', {
      p_user_id: userId,
      p_bucket: bucket,
    })
    if (error) {
      console.warn('AI request usage logging failed:', error.message)
    }
  } catch (error) {
    console.warn('AI request usage logging failed:', error)
  }
}

// Circuit breaker sul budget giornaliero di token (vedi GLOBAL_DAILY_TOKEN_BUDGET): oltre la
// soglia il proxy smette di inoltrare. Fail-open: se la lettura fallisce non si blocca il traffico.
async function globalTokensUsedToday(adminSupabase: SupabaseAdminClient): Promise<number> {
  try {
    const { data, error } = await adminSupabase.rpc('get_ai_global_tokens_today')
    if (!error && typeof data === 'number') {
      return data
    }
    if (error) {
      console.warn('Failed to read global AI token usage:', error.message)
    }
  } catch (error) {
    console.warn('Failed to read global AI token usage:', error)
  }
  return 0
}

async function recordGlobalTokens(adminSupabase: SupabaseAdminClient, tokens: number) {
  if (!Number.isFinite(tokens) || tokens <= 0) return
  try {
    const { error } = await adminSupabase.rpc('log_ai_global_tokens', {
      p_tokens: Math.round(tokens),
    })
    if (error) {
      console.warn('Global AI token logging failed:', error.message)
    }
  } catch (error) {
    console.warn('Global AI token logging failed:', error)
  }
}

serve(withCors(async (req) => {
  try {
    // 1. Require Authorization header
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return jsonResponse({ error: 'Missing Authorization header' }, 401)
    }

    // 2. Verify JWT — creates per-request client carrying the caller's token
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } }
    })
    const token = authHeader.replace('Bearer ', '')
    // `authenticatedUserId` e non `getUser` diretto: quest'ultimo pretende che la SESSIONE
    // GoTrue esista ancora, e un logout globale su un altro device la cancella lasciando
    // l'access token valido per un'altra ora. Vedi `_shared/userToken.ts`.
    const userId = await authenticatedUserId(supabase, token)
    if (!userId) {
      return jsonResponse({ error: 'Invalid or expired session' }, 401)
    }

    if (!VERTEX_SERVICE_ACCOUNT || !VERTEX_PROJECT_ID) {
      return jsonResponse({ error: 'Vertex AI credentials are not configured' }, 500)
    }

    if (!SUPABASE_SERVICE_ROLE_KEY) {
      return jsonResponse({ error: 'Supabase service role key is not configured' }, 500)
    }

    // 3. Parse the body first: the quota bucket depends on the client-sent feature tag.
    const body = await req.text()
    let parsedBody: Record<string, unknown>
    try {
      parsedBody = parseRequestBody(body)
    } catch (_) {
      return jsonResponse({ error: 'Invalid JSON request body' }, 400)
    }
    const bucket = bucketForRequest(parsedBody)

    const adminSupabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const todayKey = usageDayKey()
    const isPro = await isProUser(userId)
    const usedToday = await requestsUsedToday(adminSupabase, userId, todayKey, bucket)
    const dailyLimit = dailyLimitForTier(isPro, bucket)

    if (hasReachedDailyLimit(usedToday, isPro, bucket)) {
      return jsonResponse({
        error: 'Daily AI request limit reached',
        requestsUsedToday: usedToday,
        dailyLimit,
        isPro,
        bucket,
      }, 429)
    }

    // Circuit breaker sul credito Vertex: oltre la soglia si smette di inoltrare per tutti,
    // a prescindere dalle quote individuali.
    const globalTokens = await globalTokensUsedToday(adminSupabase)
    if (globalTokens > GLOBAL_DAILY_TOKEN_BUDGET) {
      return jsonResponse({
        error: 'global_capacity',
        message: 'Daily AI capacity reached, try again tomorrow',
      }, 429)
    }

    // 4. Forward request upstream, con model e system prompt scelti dal gateway.
    const upstreamResp = await callVertex(JSON.stringify(requestBodyForUpstream(parsedBody, bucket)))
    const respBody = await upstreamResp.text()

    if (!upstreamResp.ok) {
      console.error(`Vertex request failed (${upstreamResp.status}):`, respBody.slice(0, 500))

      // 402 (credito finito), 429 e 503 (capacita' del servizio) dicono tutti la stessa cosa a
      // chi ha lo schermo davanti: l'AI e' spenta, non e' colpa sua e non si sblocca a
      // mezzanotte. Il 429 in particolare NON puo' uscire come 429 nostro, che il client
      // mostra come "hai raggiunto il limite giornaliero" — addosso a chi non ha speso nulla.
      if (isUpstreamCapacity(upstreamResp.status)) {
        return jsonResponse({ error: 'upstream_capacity' }, 402)
      }

      return jsonResponse({
        error: 'upstream_error',
        status: upstreamResp.status,
        details: respBody,
      }, 502)
    }

    // 5. Count one successful request on the right bucket + feed the global token ledger.
    await recordSuccessfulRequest(adminSupabase, userId, bucket)

    // 6. Return the upstream response with the authoritative usage embedded in the body
    // (vw_usage): gli header custom possono essere filtrati dai gateway, il body no.
    // Gli header X-AI-* restano come canale secondario.
    let outBody = respBody
    try {
      const parsed = JSON.parse(respBody)
      const totalTokens = parsed?.usage?.total_tokens
      if (typeof totalTokens === 'number') {
        await recordGlobalTokens(adminSupabase, totalTokens)
      }
      parsed.vw_usage = {
        bucket,
        requests_used: usedToday + 1,
        daily_limit: dailyLimit,
        is_pro: isPro,
      }
      outBody = JSON.stringify(parsed)
    } catch (_) {
      // Body non parsabile: si inoltra raw, il client ricade sugli header/fallback locale.
    }

    return new Response(outBody, {
      status: upstreamResp.status,
      headers: {
        'Content-Type': 'application/json',
        'X-AI-Bucket': bucket,
        'X-AI-Requests-Used': String(usedToday + 1),
        'X-AI-Daily-Limit': String(dailyLimit),
        'X-AI-Is-Pro': String(isPro),
      }
    })
  } catch (error) {
    console.error('cerebras-proxy error:', error)
    return jsonResponse({ error: 'Internal server error' }, 500)
  }
}))
