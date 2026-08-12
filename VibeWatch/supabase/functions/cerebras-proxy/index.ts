import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  dailyLimitForTier,
  hasReachedDailyLimit,
  requestBodyForCerebras,
  usageCountForToday,
  usageDayKey,
} from './quota.ts'

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
const CEREBRAS_API_KEY = Deno.env.get('CEREBRAS_API_KEY') ?? ''
const CEREBRAS_ENDPOINT = 'https://api.cerebras.ai/v1/chat/completions'

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

function jsonResponse(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function isEntitlementActive(entitlement: { expires_date?: string | null } | undefined): boolean {
  if (!entitlement) return false
  // expires_date null => entitlement a vita (lifetime). Altrimenti deve essere nel futuro.
  if (entitlement.expires_date == null) return true
  return new Date(entitlement.expires_date).getTime() > Date.now()
}

// Verifica lo stato Pro interrogando RevenueCat (autorevole), con cache breve.
// In caso di errore/secret mancante NON si ricade sul DB forgiabile: si usa l'ultimo
// stato noto in cache (se presente) o, in assenza, il tier Free (default sicuro).
async function isProUser(userId: string): Promise<boolean> {
  const now = Date.now()
  const cached = proStatusCache.get(userId)
  if (cached && cached.expiresAt > now) {
    return cached.isPro
  }

  if (!REVENUECAT_API_KEY) {
    console.warn('REVENUECAT_API_KEY non configurata; uso ultimo stato noto / Free')
    return cached?.isPro ?? false
  }

  try {
    const resp = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`,
      { headers: { Authorization: `Bearer ${REVENUECAT_API_KEY}` } },
    )

    if (!resp.ok) {
      console.warn(`RevenueCat lookup fallita (${resp.status}); uso ultimo stato noto / Free`)
      return cached?.isPro ?? false
    }

    const json = await resp.json()
    const entitlement = json?.subscriber?.entitlements?.[PRO_ENTITLEMENT_ID]
    const isPro = isEntitlementActive(entitlement)
    proStatusCache.set(userId, { isPro, expiresAt: now + PRO_CACHE_TTL_MS })
    return isPro
  } catch (error) {
    console.warn('Errore lookup RevenueCat; uso ultimo stato noto / Free:', error)
    return cached?.isPro ?? false
  }
}

async function requestsUsedToday(
  adminSupabase: SupabaseAdminClient,
  userId: string,
  todayKey: string,
): Promise<number> {
  try {
    const { data, error } = await adminSupabase
      .from('user_ai_token_usage')
      .select('request_count, usage_date, last_updated')
      .eq('user_id', userId)
      .limit(1)

    if (error) {
      console.warn('Failed to read AI request usage:', error.message)
      return 0
    }

    return usageCountForToday(data?.[0] ?? null, todayKey)
  } catch (error) {
    console.warn('Failed to read AI request usage:', error)
  }

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

  return 0
}

async function recordSuccessfulRequest(
  adminSupabase: SupabaseAdminClient,
  userId: string,
) {
  // Single writer for the daily request counter: the log_ai_token_usage RPC. It increments
  // request_count atomically on (user_id, usage_date), so it needs no read-modify-write and
  // has no conflict-target bug. (The previous direct upsert used onConflict 'user_id' while the
  // primary key is (user_id, usage_date), so it never succeeded and always fell through to here.)
  try {
    const { error } = await adminSupabase.rpc('log_ai_token_usage', {
      p_user_id: userId,
      p_requests: 1,
    })
    if (error) {
      console.warn('AI request usage logging failed:', error.message)
    }
  } catch (error) {
    console.warn('AI request usage logging failed:', error)
  }
}

serve(async (req) => {
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
    const { data: { user }, error: authError } = await supabase.auth.getUser(token)
    if (authError || !user) {
      return jsonResponse({ error: 'Invalid or expired session' }, 401)
    }

    if (!CEREBRAS_API_KEY) {
      return jsonResponse({ error: 'Cerebras API key is not configured' }, 500)
    }

    if (!SUPABASE_SERVICE_ROLE_KEY) {
      return jsonResponse({ error: 'Supabase service role key is not configured' }, 500)
    }

    const adminSupabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const todayKey = usageDayKey()
    const isPro = await isProUser(user.id)
    const usedToday = await requestsUsedToday(adminSupabase, user.id, todayKey)
    const dailyLimit = dailyLimitForTier(isPro)

    if (hasReachedDailyLimit(usedToday, isPro)) {
      return jsonResponse({
        error: 'Daily AI request limit reached',
        requestsUsedToday: usedToday,
        dailyLimit,
        isPro,
      }, 429)
    }

    // 3. Forward request to Cerebras with gateway-owned model selection.
    const body = await req.text()
    let cerebrasBody: string
    try {
      cerebrasBody = JSON.stringify(requestBodyForCerebras(body))
    } catch (_) {
      return jsonResponse({ error: 'Invalid JSON request body' }, 400)
    }

    const cerebrasResp = await fetch(CEREBRAS_ENDPOINT, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${CEREBRAS_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: cerebrasBody
    })

    const respBody = await cerebrasResp.text()

    if (!cerebrasResp.ok) {
      return jsonResponse({
        error: 'Cerebras request failed',
        status: cerebrasResp.status,
        details: respBody,
      }, cerebrasResp.status)
    }

    // 4. Count one successful chatbot request.
    await recordSuccessfulRequest(adminSupabase, user.id)

    // 5. Return raw Cerebras response.
    return new Response(respBody, {
      status: cerebrasResp.status,
      headers: { 'Content-Type': 'application/json' }
    })
  } catch (error) {
    console.error('cerebras-proxy error:', error)
    return jsonResponse({ error: 'Internal server error' }, 500)
  }
})
