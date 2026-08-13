import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
// Prefer the new secret key (sb_secret_..., auto-injected as SUPABASE_SECRET_KEYS json),
// falling back to the legacy service_role during the migration window.
const SUPABASE_SERVICE_ROLE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()
const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY') ?? ''

// Every live subscription, however it was created: an explicit "Notify me", the release
// calendar, or simply saving the title to a list (watchlist or custom).
//
// Automatic sources were excluded after the 2026-07-23 storm that announced decades-old
// catalogue titles as new releases ("The Shawshank Redemption is out now"). The source filter
// was never what fixed that, though — the window below is. A back-catalogue title has a release
// date outside the last RELEASE_WINDOW_DAYS and is skipped no matter who subscribed to it, and
// `last_notified_at is null` means each title is announced at most once, ever.
const NOTIFIABLE_SOURCES = ['notify_me', 'release_calendar', 'watchlist', 'custom_list']

// A release is news for a couple of days, not forever. The window absorbs a missed cron run
// without ever reaching back into the catalogue.
const RELEASE_WINDOW_DAYS = 2

function isoDay(offsetDays = 0) {
  return new Date(Date.now() + offsetDays * 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
}

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const today = isoDay()
    const windowStart = isoDay(-RELEASE_WINDOW_DAYS)

    const { data: alerts, error } = await supabase
      .from('release_alerts')
      .select('user_id, media_id, media_type, country_code, last_notified_at')
      .eq('is_active', true)
      .is('deleted_at', null) // the title left every list: stop watching it
      .is('last_notified_at', null) // a release happens once; never re-announce it
      .in('source', NOTIFIABLE_SOURCES)

    if (error) throw error

    // Auto-enrollment turned a handful of subscriptions into one per saved title, so the daily
    // pass is now hundreds of TMDB lookups instead of a dozen. One title is looked up once even
    // when several people saved it, and the lookups run a few at a time: sequentially, the loop
    // would spend most of a run's wall clock waiting on a network round trip it already made.
    type Details = { releaseDate: string | null; title: string }
    const detailsCache = new Map<string, Details | null>()

    const lookup = async (mediaType: string, mediaId: number, region: string): Promise<Details | null> => {
      const key = `${mediaType}:${mediaId}:${region}`
      const cached = detailsCache.get(key)
      if (cached !== undefined) return cached

      const url = `https://api.themoviedb.org/3/${mediaType}/${mediaId}?api_key=${TMDB_API_KEY}&language=en-US&region=${region}`
      const response = await fetch(url)
      if (!response.ok) {
        detailsCache.set(key, null)
        return null
      }
      const payload = await response.json()
      const details: Details = {
        releaseDate: (mediaType === 'tv' ? payload.first_air_date : payload.release_date) ?? null,
        title: payload.title ?? payload.name ?? 'New release',
      }
      detailsCache.set(key, details)
      return details
    }

    const pending = alerts ?? []
    const LOOKUP_CONCURRENCY = 8
    for (let i = 0; i < pending.length; i += LOOKUP_CONCURRENCY) {
      await Promise.all(pending.slice(i, i + LOOKUP_CONCURRENCY).map((alert) =>
        lookup(alert.media_type, alert.media_id, alert.country_code ?? 'US')
      ))
    }

    let created = 0
    for (const alert of pending) {
      const region = alert.country_code ?? 'US'
      const details = await lookup(alert.media_type, alert.media_id, region)
      if (!details) continue

      const releaseDate = details.releaseDate
      // Out in the last RELEASE_WINDOW_DAYS days only. The old check was `releaseDate > today`,
      // which skipped future releases and announced everything already released. This is also
      // what keeps automatic subscriptions safe: a catalogue title never falls in the window.
      if (!releaseDate || releaseDate > today || releaseDate < windowStart) continue

      const title = details.title
      const { error: insertError } = await supabase
        .from('notifications')
        .insert({
          user_id: alert.user_id,
          notification_type: 'new_release',
          title: 'New release',
          body: `${title} is out now.`,
          media_id: alert.media_id,
          media_type: alert.media_type,
          is_sent: false,
          category: 'new_release',
          thread_id: `release:${alert.media_type}:${alert.media_id}`,
          template_key: 'new_release',
          template_params: { title },
        })

      if (!insertError) {
        created += 1
        await supabase
          .from('release_alerts')
          .update({ last_notified_at: new Date().toISOString() })
          .eq('user_id', alert.user_id)
          .eq('media_id', alert.media_id)
          .eq('media_type', alert.media_type)
      }
    }

    return new Response(JSON.stringify({ created }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
