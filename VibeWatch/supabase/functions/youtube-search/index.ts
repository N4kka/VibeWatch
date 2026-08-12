// YouTube Data API proxy (audit DEP-004).
//
// Two problems this solves.
//
// 1. COST. `search.list` costs 100 of the project's 10.000 daily quota units. That is ~100 searches
//    a day for the WHOLE app, shared by every user — and until now each device paid 100 units for
//    the same "Dune official trailer" query. Answers are cached here, so the second device onwards
//    pays nothing. `videos.list` costs 1 unit and is cached too.
//
// 2. THE KEY. It used to ship inside the app bundle, extractable from the IPA. Anyone could drain
//    the daily quota and switch the clip feature off for every user, at no cost to themselves.
//
// Auth: the app's publishable key, not a user JWT — clips are served to anonymous users and
// requiring a login would be a functional regression. The publishable key is public by design, so
// the quota is defended by budget rather than by secrecy:
//   * a per-caller hourly cap stops one client taking everything;
//   * a global daily cap bounds what the entire world can drain, leaving headroom under the 10.000.
//
// Budgets are spent only when a call actually reaches YouTube. Cache hits are free.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import {
  adminClient,
  callerKey,
  floorToDay,
  floorToHour,
  hasSupabaseKey,
  jsonResponse,
  readCache,
  refund,
  trySpend,
  writeCache,
} from '../_shared/proxy.ts'

const YOUTUBE_API_KEY = Deno.env.get('YOUTUBE_API_KEY') ?? ''
const PROVIDER = 'youtube'

// 10.000 units/day, search.list = 100 units. 80 searches leaves 2.000 units of headroom for
// videos.list and for anything else on the same Google Cloud project.
const GLOBAL_SEARCH_PER_DAY = 80
const CALLER_SEARCH_PER_HOUR = 5

// videos.list is 1 unit; the caps are loose but non-infinite.
const GLOBAL_DETAILS_PER_DAY = 1500
const CALLER_DETAILS_PER_HOUR = 60

// Trailer results for a given title are stable for weeks; a month of caching is not aggressive.
const SEARCH_TTL_SECONDS = 30 * 24 * 60 * 60
// Video status (embeddable / privacy / upload state) can change, so re-check weekly.
const DETAILS_TTL_SECONDS = 7 * 24 * 60 * 60

interface SearchRequest {
  action?: 'search' | 'videoDetails'
  query?: string
  relevanceLanguage?: string
  maxResults?: number
  videoId?: string
}

serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  if (!hasSupabaseKey(req)) {
    return jsonResponse({ error: 'Missing Supabase key' }, 401)
  }

  if (!YOUTUBE_API_KEY) {
    console.error('YOUTUBE_API_KEY is not configured')
    return jsonResponse({ error: 'Proxy not configured' }, 500)
  }

  let body: SearchRequest
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Invalid JSON body' }, 400)
  }

  const supabase = adminClient()
  const caller = callerKey(req)
  const now = new Date()
  const action = body.action ?? 'search'

  if (action === 'videoDetails') {
    return await handleVideoDetails(supabase, body, caller, now)
  }
  return await handleSearch(supabase, body, caller, now)
})

async function handleSearch(
  supabase: ReturnType<typeof adminClient>,
  body: SearchRequest,
  caller: string,
  now: Date,
): Promise<Response> {
  const query = (body.query ?? '').trim()
  if (!query || query.length > 200) {
    return jsonResponse({ error: 'query must be 1-200 characters' }, 400)
  }

  const maxResults = Math.max(1, Math.min(body.maxResults ?? 1, 50))
  const language = body.relevanceLanguage ?? ''
  const cacheKey = `search:${query.toLowerCase()}:${language}:${maxResults}`

  const cached = await readCache(supabase, PROVIDER, cacheKey)
  if (cached !== null) {
    return jsonResponse({ items: cached, cached: true }, 200)
  }

  const allowedForCaller = await trySpend(
    supabase, PROVIDER, `${caller}:search`, floorToHour(now), CALLER_SEARCH_PER_HOUR,
  )
  if (!allowedForCaller) {
    return jsonResponse({ error: 'rate_limited', scope: 'caller' }, 429)
  }

  const allowedGlobally = await trySpend(
    supabase, PROVIDER, 'global:search', floorToDay(now), GLOBAL_SEARCH_PER_DAY,
  )
  if (!allowedGlobally) {
    console.warn(`[youtube] global daily search budget (${GLOBAL_SEARCH_PER_DAY}) reached`)
    return jsonResponse({ error: 'quota_exhausted', scope: 'global' }, 429)
  }

  const url = new URL('https://www.googleapis.com/youtube/v3/search')
  url.searchParams.set('part', 'snippet')
  url.searchParams.set('q', query)
  url.searchParams.set('type', 'video')
  url.searchParams.set('videoDuration', 'short')
  url.searchParams.set('maxResults', String(maxResults))
  url.searchParams.set('key', YOUTUBE_API_KEY)
  if (language) url.searchParams.set('relevanceLanguage', language)

  return await callYouTube(supabase, url, cacheKey, SEARCH_TTL_SECONDS, [
    { scope: `${caller}:search`, windowStart: floorToHour(now) },
    { scope: 'global:search', windowStart: floorToDay(now) },
  ])
}

async function handleVideoDetails(
  supabase: ReturnType<typeof adminClient>,
  body: SearchRequest,
  caller: string,
  now: Date,
): Promise<Response> {
  const videoId = (body.videoId ?? '').trim()
  if (!videoId || !/^[A-Za-z0-9_-]{5,20}$/.test(videoId)) {
    return jsonResponse({ error: 'videoId is not a valid YouTube id' }, 400)
  }

  const cacheKey = `videos:${videoId}`
  const cached = await readCache(supabase, PROVIDER, cacheKey)
  if (cached !== null) {
    return jsonResponse({ items: cached, cached: true }, 200)
  }

  const allowedForCaller = await trySpend(
    supabase, PROVIDER, `${caller}:details`, floorToHour(now), CALLER_DETAILS_PER_HOUR,
  )
  if (!allowedForCaller) {
    return jsonResponse({ error: 'rate_limited', scope: 'caller' }, 429)
  }

  const allowedGlobally = await trySpend(
    supabase, PROVIDER, 'global:details', floorToDay(now), GLOBAL_DETAILS_PER_DAY,
  )
  if (!allowedGlobally) {
    return jsonResponse({ error: 'quota_exhausted', scope: 'global' }, 429)
  }

  const url = new URL('https://www.googleapis.com/youtube/v3/videos')
  url.searchParams.set('part', 'status,contentDetails')
  url.searchParams.set('id', videoId)
  url.searchParams.set('key', YOUTUBE_API_KEY)

  return await callYouTube(supabase, url, cacheKey, DETAILS_TTL_SECONDS, [
    { scope: `${caller}:details`, windowStart: floorToHour(now) },
    { scope: 'global:details', windowStart: floorToDay(now) },
  ])
}

async function callYouTube(
  supabase: ReturnType<typeof adminClient>,
  url: URL,
  cacheKey: string,
  ttlSeconds: number,
  spent: { scope: string; windowStart: string }[],
): Promise<Response> {
  let response: Response
  try {
    response = await fetch(url.toString())
  } catch (e) {
    console.error(`[youtube] upstream fetch failed: ${e}`)
    await refund(supabase, PROVIDER, spent)
    return jsonResponse({ error: 'upstream_unreachable' }, 502)
  }

  const text = await response.text()

  if (!response.ok) {
    // Distinguish an exhausted Google-side quota from any other 403 — a key restricted to an iOS
    // bundle id, say, which is what a client key looks like when called from a server. Only the
    // former is fixed by waiting for the reset, and only the former should cost budget: otherwise
    // a rejected key drains the whole daily allowance without a single successful response.
    if (response.status === 403 && (text.includes('quotaExceeded') || text.includes('dailyLimitExceeded'))) {
      console.error('[youtube] Google reports the daily quota is exhausted')
      return jsonResponse({ error: 'quota_exhausted', scope: 'upstream' }, 429)
    }
    console.error(`[youtube] upstream HTTP ${response.status}: ${text.slice(0, 300)}`)
    await refund(supabase, PROVIDER, spent)
    return jsonResponse({ error: 'upstream_error', status: response.status }, 502)
  }

  let parsed: Record<string, unknown>
  try {
    parsed = JSON.parse(text)
  } catch {
    await refund(supabase, PROVIDER, spent)
    return jsonResponse({ error: 'upstream_invalid_json' }, 502)
  }

  const items = parsed['items'] ?? []
  await writeCache(supabase, PROVIDER, cacheKey, items, ttlSeconds)

  return jsonResponse({ items, cached: false }, 200)
}
