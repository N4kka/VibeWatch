// "È uscito un episodio nuovo": la notifica giornaliera, alle 05:30 UTC (dopo `refresh-backlog`).
//
// **Cosa è cambiato.** Prima questa funzione leggeva `list_items` e poi chiamava TMDB una volta
// per serie distinta — centinaia di chiamate a notte, sullo stesso catalogo che il resto del
// sistema ha già in tabella. E le leggeva *fresche*, quindi poteva annunciare un episodio che lo
// stato dell'utente non conosceva ancora: due fonti di verità per lo stesso fatto.
//
// Ora la sorgente è `tv_show_state`, che `refresh_backlog_since()` ha appena ricalcolato: chi
// segue la serie, qual è il prossimo episodio e quando esce stanno già lì. Zero chiamate TMDB,
// zero `TMDB_API_KEY`, e la notifica dice esattamente ciò che l'utente vedrà aprendo l'app.
//
// Restano invariati: solo chiamante di servizio, `dryRun`/`windowDays` per la diagnostica, il
// cooldown di 7 giorni per (utente, serie) e la forma della notifica (`episode_aired`,
// `thread_id: episode:{id}`), perché il resto della pipeline li usa così.

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

// The cron runs at a fixed UTC hour while episodes air in local time, so "today" has to be a
// two-day window or genuine airings fall through the crack. The 7-day per-series dedup below
// keeps the window from producing a second notification for the same episode.
const AIRED_WINDOW_DAYS = 1
const SERIES_COOLDOWN_DAYS = 7

type PendingRow = {
  user_id: string
  tmdb_show_id: number
  next_season: number | null
  next_episode: number | null
  next_air_date: string | null
}

function isoDay(offsetDays = 0) {
  return new Date(Date.now() + offsetDays * 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
}

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

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

    // Lo stato appena ricalcolato: `next_air_date` dentro la finestra vuol dire "è appena
    // uscito", e `user_status = 'active'` esclude chi ha messo la serie in pausa.
    const { data: rows, error } = await supabase
      .from('tv_show_state')
      .select('user_id, tmdb_show_id, next_season, next_episode, next_air_date')
      .eq('user_status', 'active')
      .gte('next_air_date', windowStart)
      .lte('next_air_date', today)

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
    const pending: PendingRow[] = []
    for (const row of (rows ?? []) as PendingRow[]) {
      const key = `${row.user_id}:${row.tmdb_show_id}`
      if (seen.has(key) || inCooldown.has(key)) continue
      seen.add(key)
      pending.push(row)
    }

    // I nomi delle serie: una lettura sola su `tmdb_shows`, sugli id distinti.
    const showIds = [...new Set(pending.map((r) => r.tmdb_show_id))]
    const names = new Map<number, string>()
    for (let i = 0; i < showIds.length; i += 500) {
      const { data: shows, error: showsError } = await supabase
        .from('tmdb_shows')
        .select('tmdb_show_id, name')
        .in('tmdb_show_id', showIds.slice(i, i + 500))
      if (showsError) throw showsError
      for (const s of shows ?? []) names.set(s.tmdb_show_id as number, (s.name as string) ?? '')
    }

    const matched: string[] = []
    let created = 0

    for (const row of pending) {
      const name = names.get(row.tmdb_show_id) || 'A series you follow'
      const label = row.next_season != null && row.next_episode != null
        ? `S${String(row.next_season).padStart(2, '0')}E${String(row.next_episode).padStart(2, '0')}`
        : null

      const body = label
        ? `${name} ${label} is out.`
        : `${name} has a new episode out.`

      if (dryRun) {
        matched.push(`${name} (${row.next_air_date})`)
        created += 1
        continue
      }

      const { error: insertError } = await supabase
        .from('notifications')
        .insert({
          user_id: row.user_id,
          notification_type: 'episode_aired',
          title: 'New episode available',
          body,
          media_id: row.tmdb_show_id,
          media_type: 'tv',
          is_sent: false,
          category: 'episode_aired',
          thread_id: `episode:${row.tmdb_show_id}`,
          template_key: 'episode_aired',
          template_params: { show: name, episode: label },
        })

      if (!insertError) created += 1
    }

    return new Response(JSON.stringify({ created, seriesChecked: showIds.length, dryRun, windowDays, matched }), {
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
