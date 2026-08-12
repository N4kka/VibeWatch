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

// Only alerts the user explicitly asked for. `watchlist` rows are created by the
// list_items_create_alert trigger for *every* item added to a watchlist — they exist so
// check-availability knows who to tell when a title reaches streaming, not so we can announce
// that a decades-old catalogue title "is out now". Including them here is what produced the
// 2026-07-23 storm ("The Shawshank Redemption is out now").
const NOTIFIABLE_SOURCES = ['notify_me', 'release_calendar']

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
      .is('last_notified_at', null) // a release happens once; never re-announce it
      .in('source', NOTIFIABLE_SOURCES)

    if (error) throw error

    let created = 0
    for (const alert of alerts ?? []) {
      const region = alert.country_code ?? 'US'
      const url = `https://api.themoviedb.org/3/${alert.media_type}/${alert.media_id}?api_key=${TMDB_API_KEY}&language=en-US&region=${region}`
      const response = await fetch(url)
      if (!response.ok) continue

      const details = await response.json()
      const releaseDate = alert.media_type === 'tv' ? details.first_air_date : details.release_date
      // Out in the last RELEASE_WINDOW_DAYS days only. The old check was `releaseDate > today`,
      // which skipped future releases and announced everything already released.
      if (!releaseDate || releaseDate > today || releaseDate < windowStart) continue

      const title = details.title ?? details.name ?? 'New release'
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
