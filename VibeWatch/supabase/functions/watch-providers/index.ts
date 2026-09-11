// Streaming-availability proxy (audit DEP-005).
//
// The RapidAPI key used to ship in the app bundle, and the service is metered: the code comment on
// StreamingAvailabilityService records a 1.000 requests/MONTH free tier, shared by ~305 users.
// That is roughly three requests per user per month, spent per device — the same title looked up on
// two phones cost two requests. Cached here, it costs one, for everyone, for a month.
//
// This returns the upstream payload unchanged so the client keeps its existing decoding and its
// merge with TMDB's watch/providers. The client already degrades to TMDB-only when this fails, so a
// 429 from here is a soft failure by design: the user still sees providers, just without the deep
// links and pricing this service adds.
//
// Auth and budget: same model as youtube-search — publishable key, per-caller hourly cap plus a
// global monthly cap that keeps the shared allowance from being drained.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import {
  adminClient,
  callerKey,
  floorToHour,
  floorToMonth,
  hasSupabaseKey,
  jsonResponse,
  readCache,
  refund,
  trySpend,
  writeCache,
} from '../_shared/proxy.ts'
import { withCors } from '../_shared/cors.ts'

const RAPIDAPI_KEY = Deno.env.get('RAPIDAPI_KEY') ?? ''
const RAPIDAPI_HOST = 'streaming-availability.p.rapidapi.com'
const PROVIDER = 'streaming_availability'

// 900 of the 1.000/month tier, leaving headroom before the hard cutoff.
const GLOBAL_CALLS_PER_MONTH = 900
const CALLER_CALLS_PER_HOUR = 10

// Availability moves when licensing deals change — weeks, not hours.
const TTL_SECONDS = 7 * 24 * 60 * 60

interface ProvidersRequest {
  tmdbId?: number
  mediaType?: string
  region?: string
}

serve(withCors(async (req: Request) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  if (!hasSupabaseKey(req)) {
    return jsonResponse({ error: 'Missing Supabase key' }, 401)
  }

  if (!RAPIDAPI_KEY) {
    console.error('RAPIDAPI_KEY is not configured')
    return jsonResponse({ error: 'Proxy not configured' }, 500)
  }

  let body: ProvidersRequest
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Invalid JSON body' }, 400)
  }

  const tmdbId = body.tmdbId
  if (!Number.isInteger(tmdbId) || (tmdbId as number) <= 0) {
    return jsonResponse({ error: 'tmdbId must be a positive integer' }, 400)
  }

  // The upstream path segment is 'movie' or 'series'; accept the client's MediaType spelling too.
  const rawType = (body.mediaType ?? 'movie').toLowerCase()
  const showType = rawType === 'tv' || rawType === 'series' ? 'series' : 'movie'

  const region = (body.region ?? 'us').toLowerCase()
  if (!/^[a-z]{2}$/.test(region)) {
    return jsonResponse({ error: 'region must be a 2-letter country code' }, 400)
  }

  const supabase = adminClient()
  const cacheKey = `${showType}:${tmdbId}:${region}`

  const cached = await readCache(supabase, PROVIDER, cacheKey)
  if (cached !== null) {
    return jsonResponse({ show: cached, cached: true }, 200)
  }

  const now = new Date()

  const allowedForCaller = await trySpend(
    supabase, PROVIDER, caller_scope(req), floorToHour(now), CALLER_CALLS_PER_HOUR,
  )
  if (!allowedForCaller) {
    return jsonResponse({ error: 'rate_limited', scope: 'caller' }, 429)
  }

  const allowedGlobally = await trySpend(
    supabase, PROVIDER, 'global', floorToMonth(now), GLOBAL_CALLS_PER_MONTH,
  )
  if (!allowedGlobally) {
    console.warn(`[streaming] global monthly budget (${GLOBAL_CALLS_PER_MONTH}) reached`)
    return jsonResponse({ error: 'quota_exhausted', scope: 'global' }, 429)
  }

  // Budget is spent before the call; hand it back if the call fails for a reason that is not
  // "we ran out", or a broken upstream would drain the monthly allowance with zero successes.
  const refundSpent = () => refund(supabase, PROVIDER, [
    { scope: caller_scope(req), windowStart: floorToHour(now) },
    { scope: 'global', windowStart: floorToMonth(now) },
  ])

  const url = new URL(`https://${RAPIDAPI_HOST}/shows/${showType}/${tmdbId}`)
  url.searchParams.set('country', region)

  let response: Response
  try {
    response = await fetch(url.toString(), {
      headers: {
        'X-RapidAPI-Key': RAPIDAPI_KEY,
        'X-RapidAPI-Host': RAPIDAPI_HOST,
      },
    })
  } catch (e) {
    console.error(`[streaming] upstream fetch failed: ${e}`)
    await refundSpent()
    return jsonResponse({ error: 'upstream_unreachable' }, 502)
  }

  const text = await response.text()

  if (!response.ok) {
    if (response.status === 429) {
      console.error('[streaming] RapidAPI reports the plan quota is exhausted')
      return jsonResponse({ error: 'quota_exhausted', scope: 'upstream' }, 429)
    }
    // 404 means the title simply is not in their catalogue: cache the negative answer so the same
    // lookup does not burn a request from the monthly allowance every time it is retried.
    if (response.status === 404) {
      await writeCache(supabase, PROVIDER, cacheKey, null, TTL_SECONDS)
      return jsonResponse({ show: null, cached: false }, 200)
    }
    console.error(`[streaming] upstream HTTP ${response.status}: ${text.slice(0, 300)}`)
    await refundSpent()
    return jsonResponse({ error: 'upstream_error', status: response.status }, 502)
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    await refundSpent()
    return jsonResponse({ error: 'upstream_invalid_json' }, 502)
  }

  await writeCache(supabase, PROVIDER, cacheKey, parsed, TTL_SECONDS)
  return jsonResponse({ show: parsed, cached: false }, 200)
}))

function caller_scope(req: Request): string {
  return callerKey(req)
}
