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

    // Find unique TV shows across all users' lists
    const { data: items, error } = await supabase
      .from('list_items')
      .select('user_id, media_id')
      .eq('media_type', 'tv')

    if (error) throw error

    // Deduplicate by (user_id, media_id) and batch by media_id for TMDB calls
    const seen = new Set<string>()
    const unique: Array<{ user_id: string; media_id: number }> = []
    for (const item of items ?? []) {
      const key = `${item.user_id}:${item.media_id}`
      if (!seen.has(key)) {
        seen.add(key)
        unique.push(item)
      }
    }

    // Cache TMDB results to avoid duplicate calls for the same show
    const tmdbCache = new Map<number, { name: string; next_episode_air_date: string | null }>()
    let created = 0

    for (const item of unique) {
      let showData = tmdbCache.get(item.media_id)
      if (!showData) {
        const res = await fetch(
          `https://api.themoviedb.org/3/tv/${item.media_id}?api_key=${TMDB_API_KEY}&language=en-US`
        )
        if (!res.ok) continue
        const json = await res.json()
        showData = {
          name: json.name ?? 'A series you follow',
          next_episode_air_date: json.next_episode_to_air?.air_date ?? null,
        }
        tmdbCache.set(item.media_id, showData)
      }

      const airDate = showData.next_episode_air_date
      if (!airDate || airDate > today) continue

      // Dedup: skip if already notified for this show in last 7 days
      const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()
      const { count } = await supabase
        .from('notifications')
        .select('id', { count: 'exact', head: true })
        .eq('user_id', item.user_id)
        .eq('media_id', item.media_id)
        .eq('notification_type', 'episode_aired')
        .gte('created_at', sevenDaysAgo)

      if ((count ?? 0) > 0) continue

      const { error: insertError } = await supabase
        .from('notifications')
        .insert({
          user_id: item.user_id,
          notification_type: 'episode_aired',
          title: 'New episode available',
          body: `${showData.name} has a new episode out today.`,
          media_id: item.media_id,
          media_type: 'tv',
          is_sent: false,
          category: 'episode_aired',
          thread_id: `episode:${item.media_id}`,
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
