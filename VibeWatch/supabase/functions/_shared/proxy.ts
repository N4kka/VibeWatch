// Shared plumbing for the client-facing API proxies (audit DEP-004 / DEP-005).
//
// Both proxies exist for the same reason: the upstream quota is shared by the whole user base, and
// paying it per device is what makes it run out. youtube/v3/search costs 100 of the project's
// 10.000 daily units — roughly 100 searches a day for everyone combined — and RapidAPI's
// streaming-availability tier is 1.000 requests a MONTH. A cached answer serves every user.
//
// Auth: these accept the app's publishable key rather than a user JWT, because clips are served to
// anonymous users too and requiring a login would be a functional regression. The publishable key
// is public by design, so the quota is protected by budget, not by secrecy: a per-caller limit
// stops one client taking everything, and a global limit caps what the whole world can drain.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''

// Admin (RLS-bypassing) key: prefer the new secret key, fall back to legacy service_role.
// Same resolution order as cerebras-proxy.
const SUPABASE_SERVICE_ROLE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) {
    try {
      const k = JSON.parse(s)?.default
      if (k) return k as string
    } catch { /* fall back */ }
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()

export const adminClient = () =>
  createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  })

export function jsonResponse(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

/// Rejects callers that present no Supabase key at all. This is a shut-the-door check, not a
/// security boundary — the publishable key ships in the app. The budget below is the real control.
export function hasSupabaseKey(req: Request): boolean {
  const apikey = req.headers.get('apikey') ?? ''
  const auth = req.headers.get('Authorization') ?? ''
  return apikey.length > 0 || auth.startsWith('Bearer ')
}

/// Identifies the caller for per-caller limits. Best effort: an IP is spoofable in principle, but
/// combined with the global cap it is enough to stop one client draining the shared budget.
export function callerKey(req: Request): string {
  const forwarded = req.headers.get('x-forwarded-for') ?? ''
  const ip = forwarded.split(',')[0]?.trim()
  return ip && ip.length > 0 ? `ip:${ip}` : 'ip:unknown'
}

export function floorToHour(date: Date): string {
  const d = new Date(date)
  d.setUTCMinutes(0, 0, 0)
  return d.toISOString()
}

export function floorToDay(date: Date): string {
  const d = new Date(date)
  d.setUTCHours(0, 0, 0, 0)
  return d.toISOString()
}

export function floorToMonth(date: Date): string {
  const d = new Date(date)
  d.setUTCDate(1)
  d.setUTCHours(0, 0, 0, 0)
  return d.toISOString()
}

export interface CachedPayload {
  payload: unknown
  cached: boolean
}

/// Reads a non-expired cached answer, if any. A hit costs no upstream quota.
export async function readCache(
  supabase: ReturnType<typeof adminClient>,
  provider: string,
  cacheKey: string,
): Promise<unknown | null> {
  const { data, error } = await supabase
    .from('api_proxy_cache')
    .select('payload, expires_at')
    .eq('provider', provider)
    .eq('cache_key', cacheKey)
    .maybeSingle()

  if (error || !data) return null
  if (new Date(data.expires_at).getTime() <= Date.now()) return null

  // Best-effort popularity signal; never block the response on it.
  supabase.rpc('api_proxy_bump_hit', { p_provider: provider, p_cache_key: cacheKey })
    .then(() => {}, () => {})

  return data.payload
}

export async function writeCache(
  supabase: ReturnType<typeof adminClient>,
  provider: string,
  cacheKey: string,
  payload: unknown,
  ttlSeconds: number,
): Promise<void> {
  const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString()
  const { error } = await supabase
    .from('api_proxy_cache')
    .upsert(
      { provider, cache_key: cacheKey, payload, expires_at: expiresAt, created_at: new Date().toISOString() },
      { onConflict: 'provider,cache_key' },
    )
  if (error) {
    // A cache write failure must not fail the request — the caller already has its answer.
    console.warn(`[${provider}] cache write failed: ${error.message}`)
  }
}

/// Spends one unit against a budget window. Returns false when the limit is already reached.
export async function trySpend(
  supabase: ReturnType<typeof adminClient>,
  provider: string,
  scope: string,
  windowStart: string,
  limit: number,
): Promise<boolean> {
  const { data, error } = await supabase.rpc('api_proxy_try_spend', {
    p_provider: provider,
    p_scope: scope,
    p_window_start: windowStart,
    p_limit: limit,
  })

  if (error) {
    // Fail CLOSED: if the budget cannot be accounted for, do not spend upstream quota. Getting
    // this backwards is how a broken counter turns into an exhausted quota.
    console.error(`[${provider}] budget check failed, refusing upstream call: ${error.message}`)
    return false
  }

  return data === true
}

/// Gives a spent unit back when the upstream call failed for a reason that is not "we ran out".
///
/// Budget is spent before the call, which is what makes the limit hold under concurrency — but it
/// means a broken upstream (a rejected key, a 502) would otherwise drain the whole daily allowance
/// without a single successful response, and then report the quota as exhausted. Only genuine
/// upstream quota errors should consume budget.
export async function refund(
  supabase: ReturnType<typeof adminClient>,
  provider: string,
  scopes: { scope: string; windowStart: string }[],
): Promise<void> {
  for (const { scope, windowStart } of scopes) {
    const { error } = await supabase.rpc('api_proxy_refund', {
      p_provider: provider,
      p_scope: scope,
      p_window_start: windowStart,
    })
    if (error) console.warn(`[${provider}] refund failed for ${scope}: ${error.message}`)
  }
}
