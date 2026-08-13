// Sunday evening: what is coming this week on the titles you saved, and what happened last week.
//
// This is the one message in the system that is *scheduled* rather than triggered by an event,
// so it is also the one that most easily becomes noise. Two rules keep it honest: it only goes
// to people who have actually saved something (a recap of an empty library is an ad), and it is
// skipped entirely when both of its sections would be empty. Nothing to say, nothing sent.
//
// It runs an hour after the Sunday digest on purpose: on the one day both fire, the daily news
// claims the shared Resend budget first.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'
import { EmailItem, renderWeeklyRecapEmail } from '../_shared/emailTemplates.ts'
import { emailsSentToday, sendEmailWithBudget } from '../_shared/resendBudget.ts'
import { localizedCopy, NotificationRow } from '../_shared/notificationCopy.ts'
import { t } from '../_shared/i18n.ts'

const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY') ?? ''
const TMDB_API_URL = 'https://api.themoviedb.org/3'

const RECAP_TYPES = ['new_release', 'new_availability', 'episode_aired']
const UPCOMING_DAYS = 7
const RUN_BUDGET_MS = 110_000
// One user cannot be told about fifty upcoming titles in a single email; the rest are still on
// their list, in the app, where a list belongs.
const MAX_UPCOMING_PER_USER = 6

type AlertRow = { user_id: string; media_id: number; media_type: string }

type TitleInfo = { title: string; date: string | null; posterPath: string | null }

function isoDay(offsetDays = 0) {
  return new Date(Date.now() + offsetDays * 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
}

serve(async (req) => {
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  const deadline = Date.now() + RUN_BUDGET_MS

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      (() => {
        const s = Deno.env.get('SUPABASE_SECRET_KEYS')
        if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
        return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      })()
    )

    const resendApiKey = Deno.env.get('RESEND_API_KEY')
    const fromEmail = Deno.env.get('FROM_EMAIL')
    if (!resendApiKey || !fromEmail) throw new Error('Missing RESEND_API_KEY / FROM_EMAIL.')

    const { data: alerts, error } = await supabase
      .from('release_alerts')
      .select('user_id, media_id, media_type')
      .eq('is_active', true)
      .is('deleted_at', null)
      .is('last_notified_at', null) // already-released titles are not "coming up"

    if (error) throw error
    if (!alerts || alerts.length === 0) {
      return new Response(JSON.stringify({ message: 'Nobody has saved anything upcoming.', sent: 0 }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }

    // One TMDB lookup per distinct title, not per (user, title): the same film sits on many
    // lists, and its release date does not depend on who saved it.
    const distinct = new Map<string, { mediaId: number; mediaType: string }>()
    for (const alert of alerts as AlertRow[]) {
      distinct.set(`${alert.media_type}:${alert.media_id}`, {
        mediaId: alert.media_id,
        mediaType: alert.media_type,
      })
    }

    const today = isoDay()
    const horizon = isoDay(UPCOMING_DAYS)
    const info = new Map<string, TitleInfo>()

    const entries = [...distinct.entries()]
    const CONCURRENCY = 8
    for (let i = 0; i < entries.length && Date.now() < deadline; i += CONCURRENCY) {
      await Promise.all(entries.slice(i, i + CONCURRENCY).map(async ([key, item]) => {
        const response = await fetch(
          `${TMDB_API_URL}/${item.mediaType}/${item.mediaId}?api_key=${TMDB_API_KEY}&language=en-US`
        )
        if (!response.ok) return
        const payload = await response.json()
        info.set(key, {
          title: payload.title ?? payload.name ?? '',
          date: (item.mediaType === 'tv' ? payload.first_air_date : payload.release_date) ?? null,
          posterPath: payload.poster_path ?? null,
        })
      }))
    }

    const upcomingByUser = new Map<string, TitleInfo[]>()
    for (const alert of alerts as AlertRow[]) {
      const detail = info.get(`${alert.media_type}:${alert.media_id}`)
      if (!detail?.date || !detail.title) continue
      if (detail.date <= today || detail.date > horizon) continue

      const bucket = upcomingByUser.get(alert.user_id) ?? []
      if (bucket.length >= MAX_UPCOMING_PER_USER) continue
      bucket.push(detail)
      upcomingByUser.set(alert.user_id, bucket)
    }

    // Everything the user was told about their library in the last seven days, whether the push
    // reached them, was collapsed into a digest, or was held back by their own daily cap.
    const weekStart = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()
    const candidateIds = [...new Set((alerts as AlertRow[]).map((a) => a.user_id))]

    const { data: pastRows } = await supabase
      .from('notifications')
      .select('id, user_id, notification_type, title, body, template_key, template_params')
      .in('notification_type', RECAP_TYPES)
      .in('user_id', candidateIds)
      .gte('created_at', weekStart)

    const pastByUser = new Map<string, NotificationRow[]>()
    for (const row of (pastRows ?? []) as NotificationRow[]) {
      const bucket = pastByUser.get(row.user_id)
      if (bucket) bucket.push(row)
      else pastByUser.set(row.user_id, [row])
    }

    const { data: preferenceRows } = await supabase
      .from('user_notification_preferences')
      .select('user_id, weekly_recap_enabled, language')
      .in('user_id', candidateIds)

    const preferencesByUser = new Map<string, { weekly_recap_enabled: boolean | null; language: string | null }>()
    preferenceRows?.forEach((row: { user_id: string; weekly_recap_enabled: boolean | null; language: string | null }) => {
      preferencesByUser.set(row.user_id, row)
    })

    let spentToday = await emailsSentToday(supabase)
    let sent = 0
    let skippedOptOut = 0
    let skippedEmpty = 0
    let skippedBudget = 0

    for (const userId of candidateIds) {
      const preferences = preferencesByUser.get(userId)
      if (preferences?.weekly_recap_enabled === false) { skippedOptOut += 1; continue }

      const language = preferences?.language ?? null
      const upcoming: EmailItem[] = (upcomingByUser.get(userId) ?? []).map((item) => ({
        title: item.title,
        posterPath: item.posterPath,
        subtitle: t(language, 'email.upcoming.item', { date: item.date ?? '' }),
      }))
      const pastWeek: EmailItem[] = (pastByUser.get(userId) ?? []).map((row) => {
        const copy = localizedCopy(row, language)
        return { title: copy.title, subtitle: copy.body }
      })

      if (upcoming.length === 0 && pastWeek.length === 0) { skippedEmpty += 1; continue }

      const { data: { user } } = await supabase.auth.admin.getUserById(userId)
      if (!user?.email) { skippedEmpty += 1; continue }

      const document = renderWeeklyRecapEmail(language, upcoming, pastWeek)
      const outcome = await sendEmailWithBudget(supabase, {
        userId,
        to: user.email,
        subject: document.subject,
        html: document.html,
        text: document.text,
        emailType: 'weekly_recap',
        itemCount: upcoming.length + pastWeek.length,
      }, { resendApiKey, fromEmail, spentToday })

      if (outcome.sent) {
        sent += 1
        spentToday += 1
      } else if (outcome.skipped === 'budget') {
        skippedBudget += 1
        break
      }
    }

    return new Response(
      JSON.stringify({
        message: 'Function executed.',
        candidates: candidateIds.length,
        titlesResolved: info.size,
        sent,
        skippedOptOut,
        skippedEmpty,
        skippedBudget,
      }),
      { headers: { 'Content-Type': 'application/json' }, status: 200 }
    )
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('❌ weekly-recap failed:', message)
    return new Response(JSON.stringify({ error: message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
