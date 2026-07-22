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

serve(async () => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const today = new Date().toISOString().slice(0, 10)

    const { data: alerts, error } = await supabase
      .from('release_alerts')
      .select('user_id, media_id, media_type, country_code, last_notified_at')
      .eq('is_active', true)
      .in('source', ['notify_me', 'watchlist', 'release_calendar'])

    if (error) throw error

    let created = 0
    for (const alert of alerts ?? []) {
      const region = alert.country_code ?? 'US'
      const url = `https://api.themoviedb.org/3/${alert.media_type}/${alert.media_id}?api_key=${TMDB_API_KEY}&language=en-US&region=${region}`
      const response = await fetch(url)
      if (!response.ok) continue

      const details = await response.json()
      const releaseDate = alert.media_type === 'tv' ? details.first_air_date : details.release_date
      if (!releaseDate || releaseDate > today) continue
      if (alert.last_notified_at?.slice(0, 10) === today) continue

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
