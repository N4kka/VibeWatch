// The daily availability sweep: every subscribed title, in the country the subscriber lives in.
//
// **What changed.** It used to build its work list from two places — active alerts plus every
// list_items row added in the last 90 days — and then call the check-availability *function* once
// per title over HTTP, with a 500 ms courtesy sleep between calls. Two sources meant a title
// could be checked twice; the per-title HTTP hop and the sleep meant a few hundred titles could
// not fit in an invocation's wall clock.
//
// Now `release_alerts` is the only source (saving a title to any list creates a row there — see
// the auto-enrollment migration), the check runs in-process through _shared/availability.ts, and
// the loop stops on a time budget rather than being killed mid-flight. Titles are ordered by how
// long it has been since anyone looked at them, so a run that does not get through the list
// resumes where it left off tomorrow instead of restarting from the top.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'
import { checkTitleAvailability } from '../_shared/availability.ts'

const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY')!

// Two TMDB round trips per title plus a couple of queries. The platform kills an invocation at
// around 150s, so stop issuing new work well before that and report what was left.
const RUN_BUDGET_MS = 110_000

type AlertKey = { mediaId: number; mediaType: string; countryCode: string }

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  const deadline = Date.now() + RUN_BUDGET_MS

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      // Prefer the new secret key, fall back to the legacy service_role during migration.
      (() => {
        const s = Deno.env.get('SUPABASE_SECRET_KEYS')
        if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
        return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      })()
    )

    const { data: alerts, error } = await supabase
      .from('release_alerts')
      .select('media_id, media_type, country_code')
      .eq('is_active', true)
      .is('deleted_at', null)

    if (error) throw new Error(`Failed to fetch release alerts: ${error.message}`)

    const work = new Map<string, AlertKey>()
    for (const alert of alerts ?? []) {
      const countryCode = (alert.country_code ?? 'IT').toUpperCase()
      const key = `${alert.media_type}:${alert.media_id}:${countryCode}`
      if (!work.has(key)) {
        work.set(key, { mediaId: alert.media_id, mediaType: alert.media_type, countryCode })
      }
    }

    if (work.size === 0) {
      return new Response(JSON.stringify({ message: 'No active alerts. Nothing to check.' }), {
        headers: { 'Content-Type': 'application/json' },
        status: 200,
      })
    }

    // Least recently checked first. A row with no availability record at all has never been
    // looked at, so it sorts ahead of everything: a title saved this morning is checked tonight.
    const { data: lastChecks } = await supabase
      .from('media_availability')
      .select('media_id, media_type, country_code, last_checked_at')
      .order('last_checked_at', { ascending: false })

    const lastCheckedByKey = new Map<string, string>()
    for (const row of lastChecks ?? []) {
      const key = `${row.media_type}:${row.media_id}:${(row.country_code ?? '').toUpperCase()}`
      if (!lastCheckedByKey.has(key)) lastCheckedByKey.set(key, row.last_checked_at)
    }

    const queue = [...work.entries()].sort(([keyA], [keyB]) => {
      const a = lastCheckedByKey.get(keyA) ?? ''
      const b = lastCheckedByKey.get(keyB) ?? ''
      return a.localeCompare(b)
    })

    let checked = 0
    let queuedNotifications = 0
    let newProviders = 0
    let seeded = 0
    let failed = 0
    let skippedForBudget = 0

    for (const [, item] of queue) {
      if (Date.now() > deadline) {
        skippedForBudget = queue.length - checked - failed
        console.warn(`[check-all-availability] run budget spent, ${skippedForBudget} titles deferred to the next run`)
        break
      }

      try {
        const outcome = await checkTitleAvailability(supabase, { ...item, tmdbApiKey: TMDB_API_KEY })
        checked += 1
        newProviders += outcome.newProviders
        queuedNotifications += outcome.queued
        if (outcome.seeded) seeded += 1
      } catch (e) {
        failed += 1
        const message = e instanceof Error ? e.message : String(e)
        console.error(`[check-all-availability] ${item.mediaType}:${item.mediaId} (${item.countryCode}): ${message}`)
      }
    }

    return new Response(
      JSON.stringify({
        message: 'Function executed.',
        titles: queue.length,
        checked,
        newProviders,
        seeded,
        queuedNotifications,
        failed,
        skippedForBudget,
      }),
      { headers: { 'Content-Type': 'application/json' }, status: 200 }
    )
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('❌ An error occurred:', message)

    return new Response(JSON.stringify({ error: message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
