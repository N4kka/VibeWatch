// One email a day, only when something actually happened to a title you saved.
//
// **Why this exists.** Email was a fallback and nothing else: it went out only to users who had
// never registered a device, which in practice meant it went out to nobody — the last one was
// sent in July. Meanwhile the thing users notice from competitors ("the film on your list is
// streaming now") is exactly the kind of news this system already computes and then delivers
// only as a push that may or may not survive the daily cap.
//
// So the digest is a **complementary channel, not a fallback**: it goes to everyone who wants
// it, push or no push. What keeps it from being spam is that it has no schedule of its own worth
// mentioning — no news about your saved titles, no email. There is no "here's what's trending"
// filler, and no email at all on a quiet day.
//
// Three guards, in order: the user's `email_digest_enabled`, the per-type preferences (an email
// never mentions a category the user muted for push), and one row per user per day in
// `notification_delivery_log` with `channel = 'email'`, which also makes a second cron firing
// a no-op.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'
import { EmailItem, EmailSection, renderDigestEmail } from '../_shared/emailTemplates.ts'
import { emailsSentToday, sendEmailWithBudget } from '../_shared/resendBudget.ts'
import { localizedCopy, NotificationRow } from '../_shared/notificationCopy.ts'
import { t } from '../_shared/i18n.ts'

// The three types that are about a title the user saved. A streak reminder or a new follower is
// not news about the library, and belongs in the push channel only.
const DIGEST_TYPES = ['new_release', 'new_availability', 'episode_aired'] as const
type DigestType = typeof DIGEST_TYPES[number]

const PREF_COLUMN: Record<DigestType, string> = {
  new_release: 'new_release',
  new_availability: 'new_availability',
  episode_aired: 'episode_aired',
}

const WINDOW_HOURS = 24

type PreferencesRow = {
  user_id: string
  email_digest_enabled: boolean | null
  language: string | null
  new_release: boolean | null
  new_availability: boolean | null
  episode_aired: boolean | null
}

async function alreadySentToday(supabase: SupabaseClient, userIds: string[]): Promise<Set<string>> {
  const since = new Date()
  since.setUTCHours(0, 0, 0, 0)

  const { data } = await supabase
    .from('notification_delivery_log')
    .select('user_id')
    .eq('channel', 'email')
    .eq('kind', 'digest')
    .in('user_id', userIds)
    .gte('delivered_at', since.toISOString())

  return new Set((data ?? []).map((row: { user_id: string }) => row.user_id))
}

serve(async (req) => {
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

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

    const windowStart = new Date(Date.now() - WINDOW_HOURS * 60 * 60 * 1000).toISOString()

    // Delivered or not: the email is a second channel for the same news, not a report on what
    // the push pipeline managed to do with it.
    const { data: rows, error } = await supabase
      .from('notifications')
      .select('id, user_id, notification_type, title, body, media_id, media_type, template_key, template_params')
      .in('notification_type', DIGEST_TYPES as unknown as string[])
      .gte('created_at', windowStart)

    if (error) throw error
    if (!rows || rows.length === 0) {
      return new Response(JSON.stringify({ message: 'Nothing new today.', sent: 0 }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const byUser = new Map<string, NotificationRow[]>()
    for (const row of rows as NotificationRow[]) {
      const bucket = byUser.get(row.user_id)
      if (bucket) bucket.push(row)
      else byUser.set(row.user_id, [row])
    }

    const userIds = [...byUser.keys()]
    const { data: preferenceRows } = await supabase
      .from('user_notification_preferences')
      .select('user_id, email_digest_enabled, language, new_release, new_availability, episode_aired')
      .in('user_id', userIds)

    const preferencesByUser = new Map<string, PreferencesRow>()
    preferenceRows?.forEach((row: PreferencesRow) => preferencesByUser.set(row.user_id, row))

    const sentAlready = await alreadySentToday(supabase, userIds)
    let spentToday = await emailsSentToday(supabase)

    let sent = 0
    let skippedOptOut = 0
    let skippedDuplicate = 0
    let skippedEmpty = 0
    let skippedBudget = 0

    for (const [userId, notifications] of byUser) {
      const preferences = preferencesByUser.get(userId)
      // No preferences row means the user has never opened the notification settings. Defaults
      // are opt-in, and the column default is true, so treat the absence as consent.
      if (preferences?.email_digest_enabled === false) { skippedOptOut += 1; continue }
      if (sentAlready.has(userId)) { skippedDuplicate += 1; continue }

      const language = preferences?.language ?? null
      const allowed = notifications.filter((row) => {
        const column = PREF_COLUMN[row.notification_type as DigestType]
        const value = preferences?.[column as keyof PreferencesRow]
        return value !== false
      })
      if (allowed.length === 0) { skippedEmpty += 1; continue }

      const sections: EmailSection[] = DIGEST_TYPES.map((type) => {
        const items: EmailItem[] = allowed
          .filter((row) => row.notification_type === type)
          .map((row) => {
            const copy = localizedCopy(row, language)
            // In an email the section already says what kind of news this is, so the line leads
            // with the title it is about. A push has to carry "New episode available" in its own
            // first line; a row under a "New episodes" heading would only repeat it.
            const params = row.template_params ?? {}
            const subject = String(params.show ?? params.title ?? '').trim()
            return { title: subject || copy.title, subtitle: copy.body }
          })
        return { heading: t(language, `email.section.${type}`), items }
      }).filter((section) => section.items.length > 0)

      const { data: { user } } = await supabase.auth.admin.getUserById(userId)
      if (!user?.email) { skippedEmpty += 1; continue }

      const document = renderDigestEmail(language, sections)
      const outcome = await sendEmailWithBudget(supabase, {
        userId,
        to: user.email,
        subject: document.subject,
        html: document.html,
        text: document.text,
        emailType: 'digest',
        itemCount: allowed.length,
      }, { resendApiKey, fromEmail, spentToday })

      if (outcome.sent) {
        sent += 1
        spentToday += 1
      } else if (outcome.skipped === 'budget') {
        skippedBudget += 1
        break // the ceiling is global: the rest of the loop would only log the same refusal
      }
    }

    return new Response(
      JSON.stringify({
        message: 'Function executed.',
        candidates: byUser.size,
        sent,
        skippedOptOut,
        skippedDuplicate,
        skippedEmpty,
        skippedBudget,
      }),
      { headers: { 'Content-Type': 'application/json' }, status: 200 }
    )
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('❌ email-digest failed:', message)
    return new Response(JSON.stringify({ error: message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
