// Every outgoing email goes through here, and here is where the day's budget is counted.
//
// Resend's free tier allows 100 messages a day. The same account also carries the auth mails
// (signup confirmations), which are the ones that must never be refused: a user who cannot
// confirm their address is a lost account, a missing digest is a missing digest. So the notified
// mail budget stops well short of the ceiling and leaves the rest as headroom.
//
// The counter is `email_send_log`, not an in-memory variable: the digest and the recap are two
// separate invocations, and the dispatcher's fallback path is a third.

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

export const DAILY_EMAIL_BUDGET = 80

export type EmailType = 'digest' | 'weekly_recap' | 'fallback'

export type SendResult = { sent: boolean; skipped?: 'budget' | 'no-address'; error?: string }

export async function emailsSentToday(supabase: SupabaseClient): Promise<number> {
  const since = new Date()
  since.setUTCHours(0, 0, 0, 0)

  const { count, error } = await supabase
    .from('email_send_log')
    .select('id', { count: 'exact', head: true })
    .gte('sent_at', since.toISOString())

  if (error) {
    // Failing closed here would silence a whole day of email over a transient read error, and
    // failing open risks a handful of messages past the ceiling. Neither is free; the read is
    // one indexed count, so treat an error as "budget unknown, keep going" and say so loudly.
    console.error('[resendBudget] could not read the day count:', error.message)
    return 0
  }

  return count ?? 0
}

export type OutgoingEmail = {
  userId: string
  to: string
  subject: string
  html: string
  text: string
  emailType: EmailType
  itemCount?: number
}

export async function sendEmailWithBudget(
  supabase: SupabaseClient,
  email: OutgoingEmail,
  options: { resendApiKey: string; fromEmail: string; spentToday: number }
): Promise<SendResult> {
  if (!email.to) return { sent: false, skipped: 'no-address' }
  if (options.spentToday >= DAILY_EMAIL_BUDGET) {
    console.warn(`[resendBudget] daily budget spent (${options.spentToday}/${DAILY_EMAIL_BUDGET}), skipping ${email.emailType}`)
    return { sent: false, skipped: 'budget' }
  }

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${options.resendApiKey}`,
    },
    body: JSON.stringify({
      from: options.fromEmail,
      to: email.to,
      subject: email.subject,
      html: email.html,
      text: email.text,
    }),
  })

  if (!response.ok) {
    const body = await response.text()
    console.error(`[resendBudget] ${email.emailType} rejected by Resend: ${response.status} ${body}`)
    return { sent: false, error: body }
  }

  // Logged after the send: a row here means a message left, so a crash costs at most one
  // uncounted email instead of silently burning budget on sends that never happened.
  const { error } = await supabase.from('email_send_log').insert({
    user_id: email.userId,
    email_type: email.emailType,
    item_count: email.itemCount ?? 1,
  })
  if (error) console.error('[resendBudget] send succeeded but the ledger insert failed:', error.message)

  return { sent: true }
}
