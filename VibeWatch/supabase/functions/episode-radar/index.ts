import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
// Prefer the new secret key (sb_secret_..., auto-injected as SUPABASE_SECRET_KEYS json),
// falling back to the legacy service_role during the migration window.
const SUPABASE_SERVICE_ROLE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()
const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY') ?? ''

// The cron runs at a fixed UTC hour while episodes air in local time, so "today" has to be a
// two-day window or genuine airings fall through the crack. The 7-day per-series dedup below
// keeps the window from producing a second notification for the same episode.
const AIRED_WINDOW_DAYS = 1
const SERIES_COOLDOWN_DAYS = 7

type LastEpisode = {
  air_date: string | null
  season_number?: number | null
  episode_number?: number | null
}

function isoDay(offsetDays = 0) {
  return new Date(Date.now() + offsetDays * 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
}

serve(async (req) => {
  try {
    // Diagnostics only. `dryRun` reports what would be queued without touching the table, and
    // `windowDays` widens the airing window so the predicate can be exercised on a day when
    // nothing happens to have aired. The cron sends no body, so both default off.
    let dryRun = false
    let windowDays = AIRED_WINDOW_DAYS
    try {
      const body = await req.json()
      dryRun = body?.dryRun === true
      if (Number.isFinite(body?.windowDays)) {
        windowDays = Math.min(365, Math.max(0, Math.trunc(body.windowDays)))
      }
    } catch { /* no body: cron invocation */ }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const today = isoDay()
    const windowStart = isoDay(-windowDays)
    const cooldownStart = new Date(Date.now() - SERIES_COOLDOWN_DAYS * 24 * 60 * 60 * 1000).toISOString()

    const { data: items, error } = await supabase
      .from('list_items')
      .select('user_id, media_id')
      .eq('media_type', 'tv')
      .is('deleted_at', null) // removed items must stop notifying

    if (error) throw error

    // One pass over recent notifications instead of a count query per (user, series).
    const { data: recent, error: recentError } = await supabase
      .from('notifications')
      .select('user_id, media_id')
      .eq('notification_type', 'episode_aired')
      .gte('created_at', cooldownStart)

    if (recentError) throw recentError

    const inCooldown = new Set(
      (recent ?? []).map((row: { user_id: string; media_id: number }) => `${row.user_id}:${row.media_id}`)
    )

    // Deduplicate the (user, series) pairs still eligible for a notification.
    const seen = new Set<string>()
    const pending: Array<{ user_id: string; media_id: number }> = []
    for (const item of items ?? []) {
      const key = `${item.user_id}:${item.media_id}`
      if (seen.has(key) || inCooldown.has(key)) continue
      seen.add(key)
      pending.push(item)
    }

    // One TMDB lookup per distinct series, shared across the users who follow it.
    const tmdbCache = new Map<number, { name: string; episode: LastEpisode | null }>()
    const matched: string[] = []
    let created = 0

    for (const item of pending) {
      let showData = tmdbCache.get(item.media_id)
      if (!showData) {
        const res = await fetch(
          `https://api.themoviedb.org/3/tv/${item.media_id}?api_key=${TMDB_API_KEY}&language=en-US`
        )
        if (!res.ok) continue
        const json = await res.json()
        showData = {
          name: json.name ?? 'A series you follow',
          // `last_episode_to_air` is the episode that has actually aired. The old code read
          // `next_episode_to_air`, which is by definition the one that has *not* aired yet, and
          // then fired whenever its date was in the past — announcing episodes off stale data.
          episode: (json.last_episode_to_air ?? null) as LastEpisode | null,
        }
        tmdbCache.set(item.media_id, showData)
      }

      const airDate = showData.episode?.air_date
      if (!airDate || airDate > today || airDate < windowStart) continue

      const season = showData.episode?.season_number
      const number = showData.episode?.episode_number
      const label = season != null && number != null
        ? `S${String(season).padStart(2, '0')}E${String(number).padStart(2, '0')}`
        : null

      const body = label
        ? `${showData.name} ${label} is out.`
        : `${showData.name} has a new episode out.`

      if (dryRun) {
        matched.push(`${showData.name} (${airDate})`)
        created += 1
        continue
      }

      const { error: insertError } = await supabase
        .from('notifications')
        .insert({
          user_id: item.user_id,
          notification_type: 'episode_aired',
          title: 'New episode available',
          body,
          media_id: item.media_id,
          media_type: 'tv',
          is_sent: false,
          category: 'episode_aired',
          thread_id: `episode:${item.media_id}`,
        })

      if (!insertError) created += 1
    }

    return new Response(JSON.stringify({ created, seriesChecked: tmdbCache.size, dryRun, windowDays, matched }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : String(error) }),
      { headers: { 'Content-Type': 'application/json' }, status: 500 }
    )
  }
})
