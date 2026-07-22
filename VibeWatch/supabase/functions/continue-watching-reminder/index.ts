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

// Remind users who added a TV show to their list at least 3 days ago
// but have not received a continue-watching nudge in the last 7 days.
serve(async () => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const threeDaysAgo = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()
    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()

    // TV shows added to any list at least 3 days ago
    const { data: items, error } = await supabase
      .from('list_items')
      .select('user_id, media_id, created_at')
      .eq('media_type', 'tv')
      .lte('created_at', threeDaysAgo)

    if (error) throw error

    // Deduplicate by (user_id, media_id)
    const seen = new Set<string>()
    const unique: Array<{ user_id: string; media_id: number }> = []
    for (const item of items ?? []) {
      const key = `${item.user_id}:${item.media_id}`
      if (!seen.has(key)) {
        seen.add(key)
        unique.push(item)
      }
    }

    const tmdbCache = new Map<number, string>()
    let created = 0

    for (const item of unique) {
      // Skip if a continue-watching notification was already sent in the last 7 days
      const { count } = await supabase
        .from('notifications')
        .select('id', { count: 'exact', head: true })
        .eq('user_id', item.user_id)
        .eq('media_id', item.media_id)
        .eq('notification_type', 'continue_watching')
        .gte('created_at', sevenDaysAgo)

      if ((count ?? 0) > 0) continue

      // Fetch show name from TMDB (cached per show)
      let showName = tmdbCache.get(item.media_id)
      if (!showName) {
        const res = await fetch(
          `https://api.themoviedb.org/3/tv/${item.media_id}?api_key=${TMDB_API_KEY}&language=en-US`
        )
        if (!res.ok) continue
        const json = await res.json()
        showName = json.name ?? 'A series in your list'
        tmdbCache.set(item.media_id, showName)
      }

      const { error: insertError } = await supabase
        .from('notifications')
        .insert({
          user_id: item.user_id,
          notification_type: 'continue_watching',
          title: 'Continue watching',
          body: `Pick up where you left off with ${showName}.`,
          media_id: item.media_id,
          media_type: 'tv',
          is_sent: false,
          category: 'continue_watching',
          thread_id: `continue:${item.media_id}`,
        })

      if (!insertError) created += 1
    }

    return new Response(JSON.stringify({ created }), {
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
