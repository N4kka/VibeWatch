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

// A nudge is a suggestion, so it is worth exactly one notification. The old version queued one
// per series, which meant a user with nine shows got nine pushes in four seconds and then the
// same nine together again a week later.
// Days without watching anything of the show before it is worth a nudge.
const REMINDER_AGE_DAYS = 3
// Cooldown on the *user*, not on the pair (user, series). This is what stops the burst.
const USER_COOLDOWN_DAYS = 7
// Rotate through the list instead of nagging about the same show forever.
const SERIES_COOLDOWN_DAYS = 30

type ListItem = {
  user_id: string
  media_id: number
  title: string | null
}

type TrackingRow = {
  user_id: string
  tmdb_show_id: number
  show_name: string | null
}

const PAGE = 1000

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const now = Date.now()
    const idleSince = new Date(now - REMINDER_AGE_DAYS * 24 * 60 * 60 * 1000).toISOString()
    const seriesCooldownStart = new Date(now - SERIES_COOLDOWN_DAYS * 24 * 60 * 60 * 1000).toISOString()
    const userCooldownStart = new Date(now - USER_COOLDOWN_DAYS * 24 * 60 * 60 * 1000).toISOString()

    // Candidates come from tracking, not from list rows: a series "to continue" is one the user
    // started and has an episode ready for (up_next), or left idle (stale). List rows said
    // nothing of the sort — a legacy TV row in Seen nudged people about shows they had finished.
    // Most recently watched first: the show they were last into is the best guess. Paged, since
    // PostgREST stops at 1000 rows without saying so.
    const items: ListItem[] = []
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await supabase
        .from('v_tv_tracking')
        .select('user_id, tmdb_show_id, show_name')
        .in('bucket', ['up_next', 'stale'])
        .lte('last_watched_at', idleSince)
        .order('last_watched_at', { ascending: false })
        .order('user_id')
        .order('tmdb_show_id')
        .range(from, from + PAGE - 1)
      if (error) throw error
      for (const row of (data ?? []) as TrackingRow[]) {
        items.push({ user_id: row.user_id, media_id: row.tmdb_show_id, title: row.show_name })
      }
      if (!data || data.length < PAGE) break
    }

    // One pass over the recent nudges instead of a count query per candidate.
    const { data: recentNudges, error: nudgeError } = await supabase
      .from('notifications')
      .select('user_id, media_id, created_at')
      .eq('notification_type', 'continue_watching')
      .gte('created_at', seriesCooldownStart)

    if (nudgeError) throw nudgeError

    const usersInCooldown = new Set<string>()
    const seriesInCooldown = new Set<string>()
    for (const nudge of recentNudges ?? []) {
      seriesInCooldown.add(`${nudge.user_id}:${nudge.media_id}`)
      if (nudge.created_at >= userCooldownStart) usersInCooldown.add(nudge.user_id)
    }

    const candidatesByUser = new Map<string, ListItem[]>()
    for (const item of items) {
      if (usersInCooldown.has(item.user_id)) continue
      const bucket = candidatesByUser.get(item.user_id)
      if (bucket) bucket.push(item)
      else candidatesByUser.set(item.user_id, [item])
    }

    let created = 0
    for (const [userId, candidates] of candidatesByUser) {
      const pick = candidates.find(
        (item) => !seriesInCooldown.has(`${userId}:${item.media_id}`)
      )
      if (!pick) continue // every series was nudged recently; stay quiet this round

      const showName = pick.title?.trim() || 'A series in your list'
      const { error: insertError } = await supabase
        .from('notifications')
        .insert({
          user_id: userId,
          notification_type: 'continue_watching',
          title: 'Continue watching',
          body: `Pick up where you left off with ${showName}.`,
          media_id: pick.media_id,
          media_type: 'tv',
          is_sent: false,
          category: 'continue_watching',
          thread_id: `continue:${pick.media_id}`,
          template_key: 'continue_watching',
          template_params: { show: showName },
        })

      if (!insertError) created += 1
    }

    return new Response(JSON.stringify({ created, usersConsidered: candidatesByUser.size }), {
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
