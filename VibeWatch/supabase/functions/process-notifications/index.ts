import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { SignJWT, importPKCS8 } from 'https://esm.sh/jose@v5.2.3'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'
import { renderFallbackEmail } from '../_shared/emailTemplates.ts'
import { emailsSentToday, sendEmailWithBudget } from '../_shared/resendBudget.ts'
import {
  capFor,
  classifyFcmError,
  digestPayload,
  isInQuietHours,
  localizedCopy,
  NotificationPreferences,
  NotificationRow,
  payloadForNotification,
  preferenceAllows,
  PushPayload,
  retryDelayMinutes,
  SOCIAL_DAILY_PUSH_CAP,
  SOCIAL_TYPES,
} from './logic.ts'

console.log('🚀 process-notifications function booting up...')

// Delivery is sequential and network-bound, so a run has to stay well inside the platform's
// wall-clock limit. The cron fires every 5 minutes, so a leftover queue drains on the next
// run instead of being pushed through a single oversized batch.
const BATCH_SIZE = 25
// Stop issuing new sends past this point and return normally. Being killed mid-loop is what
// used to strand delivered pushes in an unsent state.
const RUN_BUDGET_MS = 100_000
// A user who reinstalls or reinstates permissions accumulates a new user_devices row every time
// FCM rotates the token, and nothing ever prunes them (one account had 66). Sending to all of
// them means the same handset can be hit several times for one notification.
const MAX_DEVICES_PER_USER = 10
// Queued content that nobody delivered in a week is noise, not news. Retire it rather than
// dumping a backlog the moment the pipeline recovers.
const MAX_QUEUE_AGE_MS = 7 * 24 * 60 * 60 * 1000

type PushResult = {
  sent: boolean
  retryable: boolean
  permanent: boolean
  error?: string
  // 'push'             delivered to at least one live token
  // 'no-live-token'    the user registered devices once, but every token is dead (uninstalled or
  //                    revoked permission). Silence is the correct outcome — emailing them would
  //                    turn an uninstall into a mailing list.
  // 'never-registered' no device row has ever existed, so email is the only channel there is.
  outcome: 'push' | 'no-live-token' | 'never-registered'
}

async function getFirebaseAccessToken(serviceAccount: any) {
  const privateKey = serviceAccount.private_key.replace(/\\n/g, '\n')
  const privateKeyObject = await importPKCS8(privateKey, 'RS256')

  const jwt = await new SignJWT({
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    aud: 'https://oauth2.googleapis.com/token',
    scope: 'https://www.googleapis.com/auth/cloud-platform',
  })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuedAt()
    .setExpirationTime('1h')
    .sign(privateKeyObject)

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  })

  if (!response.ok) {
    const errorText = await response.text()
    throw new Error(`Failed to get Firebase access token: ${response.status} ${errorText}`)
  }

  const data = await response.json()
  return data.access_token
}

async function sendPush(
  supabaseClient: SupabaseClient,
  userId: string,
  payload: PushPayload,
  accessToken: string,
  projectId: string
): Promise<PushResult> {
  // Rows are read including dead tokens so "never had a device" stays distinguishable from
  // "device died"; only the live ones are actually sent to.
  const { data: devices, error: deviceError } = await supabaseClient
    .from('user_devices')
    .select('fcm_token')
    .eq('user_id', userId)
    // Newest first: stale rows left behind by token rotation sit at the bottom and are dropped.
    .order('updated_at', { ascending: false })
    .limit(MAX_DEVICES_PER_USER)

  if (deviceError) {
    return { sent: false, retryable: true, permanent: false, error: deviceError.message, outcome: 'push' }
  }

  if (!devices || devices.length === 0) {
    return { sent: true, retryable: false, permanent: false, outcome: 'never-registered' }
  }

  const liveDevices = devices.filter((device: { fcm_token: string | null }) => device.fcm_token)
  if (liveDevices.length === 0) {
    return { sent: true, retryable: false, permanent: false, outcome: 'no-live-token' }
  }

  let sawRetryable = false
  let sawPermanent = false
  let lastError: string | undefined

  for (const device of liveDevices) {
    const fcmToken = device.fcm_token
    const priority = payload.notificationType === 'streak_reminder' ? '5' : '10'

    const message = {
      message: {
        token: fcmToken,
        notification: {
          title: payload.title,
          body: payload.body,
        },
        data: {
          notification_id: payload.dataId,
          notification_type: payload.notificationType,
          media_id: String(payload.mediaId ?? ''),
          media_type: String(payload.mediaType ?? ''),
          // Social feed M3: le push social non hanno un media, hanno una CARD. L'id sta già in
          // thread_id (`social:{activity_id}`, la chiave con cui i trigger deduplicano) e da
          // qui il client ci apre sopra. Nell'aps c'è come `thread-id`, ma leggerlo da lì
          // vorrebbe dire frugare nel dizionario di sistema: si dichiara nei data, dove il
          // client legge già tutto il resto.
          thread_id: String(payload.threadId ?? ''),
        },
        apns: {
          headers: {
            'apns-priority': priority,
            'apns-collapse-id': payload.collapseId,
          },
          payload: {
            aps: {
              sound: 'default',
              badge: 1,
              category: payload.category,
              'thread-id': payload.threadId,
            },
          },
        },
      },
    }

    const response = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify(message),
    })

    if (!response.ok) {
      const body = await response.text()
      const result = classifyFcmError(response.status, body)
      lastError = result.error
      sawRetryable = sawRetryable || result.retryable
      sawPermanent = sawPermanent || result.permanent

      if (result.permanent) {
        await supabaseClient
          .from('user_devices')
          .update({ fcm_token: null })
          .eq('fcm_token', fcmToken)
      }
    }
  }

  return {
    sent: !sawRetryable,
    retryable: sawRetryable,
    permanent: sawPermanent,
    error: lastError,
    outcome: 'push',
  }
}

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  const deadline = Date.now() + RUN_BUDGET_MS
  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      // Prefer the new secret key, fall back to the legacy service_role during migration.
      (() => {
        const s = Deno.env.get('SUPABASE_SECRET_KEYS')
        if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
        return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      })()
    )

    const firebaseServiceAccountJson = Deno.env.get('FIREBASE_SERVICE_ACCOUNT')
    const resendApiKey = Deno.env.get('RESEND_API_KEY')
    const fromEmail = Deno.env.get('FROM_EMAIL')

    if (!firebaseServiceAccountJson || !resendApiKey || !fromEmail) {
      throw new Error('Missing required environment variables/secrets.')
    }

    const firebaseServiceAccount = JSON.parse(firebaseServiceAccountJson)

    // Each notification costs a device lookup, one FCM call per device and usually an email,
    // all sequential. At 100 per run the loop routinely blew past the platform's ~150s limit
    // and the invocation was killed mid-flight (a long run of 504s in the logs).
    const { data: notifications, error: fetchError } = await supabaseClient
      .from('notifications')
      .select('*')
      .eq('is_sent', false)
      .or(`next_retry_at.is.null,next_retry_at.lte.${new Date().toISOString()}`)
      .limit(BATCH_SIZE)

    if (fetchError) {
      throw new Error(`Error fetching notifications: ${fetchError.message}`)
    }

    if (!notifications || notifications.length === 0) {
      return new Response(JSON.stringify({ message: 'No pending notifications to process.' }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const userIds = [...new Set(notifications.map((notification: NotificationRow) => notification.user_id))]
    const { data: preferenceRows } = await supabaseClient
      .from('user_notification_preferences')
      .select('*')
      .in('user_id', userIds)

    const preferencesByUser = new Map<string, NotificationPreferences>()
    preferenceRows?.forEach((row: NotificationPreferences & { user_id: string }) => {
      preferencesByUser.set(row.user_id, row)
    })

    const firebaseAccessToken = await getFirebaseAccessToken(firebaseServiceAccount)
    // Read once per run: the fallback path shares the day's provider budget with the digest and
    // the weekly recap, and re-counting per notification would be a query per row.
    let emailsSpentToday = await emailsSentToday(supabaseClient)

    // Rows that never reach a device, so batching their bookkeeping to the end of the run is
    // safe: if the invocation dies first, nothing was sent and nothing is duplicated.
    // Actually-delivered rows are marked inline instead.
    const suppressedByPreferences: string[] = []
    const skippedForQuietHours: string[] = []
    const expired: string[] = []
    const eligibleByUser = new Map<string, NotificationRow[]>()
    const staleBefore = Date.now() - MAX_QUEUE_AGE_MS

    for (const notification of notifications as NotificationRow[]) {
      const preferences = preferencesByUser.get(notification.user_id)

      if (notification.created_at && Date.parse(notification.created_at) < staleBefore) {
        expired.push(notification.id)
        continue
      }

      if (!preferenceAllows(notification, preferences)) {
        suppressedByPreferences.push(notification.id)
        continue
      }

      if (isInQuietHours(preferences)) {
        skippedForQuietHours.push(notification.id)
        continue
      }

      const bucket = eligibleByUser.get(notification.user_id)
      if (bucket) bucket.push(notification)
      else eligibleByUser.set(notification.user_id, [notification])
    }

    // How much of each user's 24h budget is already spent. One query for the whole batch.
    // Two ledgers: social deliveries burn their own budget, everything else (including rows
    // logged before the category column existed) burns the general one.
    const windowStart = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
    const spentByUser = new Map<string, number>()
    const socialSpentByUser = new Map<string, number>()
    if (eligibleByUser.size > 0) {
      const { data: recentDeliveries } = await supabaseClient
        .from('notification_delivery_log')
        .select('user_id, category')
        .in('user_id', [...eligibleByUser.keys()])
        .gte('delivered_at', windowStart)

      recentDeliveries?.forEach((row: { user_id: string; category?: string | null }) => {
        const ledger = row.category === 'social' ? socialSpentByUser : spentByUser
        ledger.set(row.user_id, (ledger.get(row.user_id) ?? 0) + 1)
      })
    }

    const nowIso = () => new Date().toISOString()
    let deliveredCount = 0
    let emailedCount = 0
    let silencedCount = 0
    let digestCount = 0
    let cappedCount = 0
    let stoppedOnDeadline = false

    const markSent = async (ids: string[]) => {
      const { error: markError } = await supabaseClient
        .from('notifications')
        .update({ is_sent: true, sent_at: nowIso(), last_error: null })
        .in('id', ids)

      // Marking happens before anything else can fail. This used to be batched after the whole
      // loop, so a timeout left every already-delivered push flagged is_sent = false and the next
      // cron run re-sent the lot — the original duplicate-notification storm.
      if (markError) console.error(`Failed to mark ${ids.length} rows as sent:`, markError.message)
    }

    const markFailed = async (rows: NotificationRow[], error?: string) => {
      for (const row of rows) {
        const retryCount = (row.retry_count ?? 0) + 1
        await supabaseClient
          .from('notifications')
          .update({
            retry_count: retryCount,
            next_retry_at: new Date(Date.now() + retryDelayMinutes(retryCount) * 60 * 1000).toISOString(),
            last_error: error ?? 'unknown push failure',
          })
          .eq('id', row.id)
      }
    }

    for (const [userId, rows] of eligibleByUser) {
      // Leave the remaining rows untouched rather than being killed mid-delivery.
      if (Date.now() > deadline) {
        stoppedOnDeadline = true
        break
      }

      const preferences = preferencesByUser.get(userId)
      const language = preferences?.language ?? null

      // Two independent buckets per user: social rows never displace episode reminders from the
      // general budget, and vice versa. The general cap is the user's own setting; the social one
      // is a safety rail against a burst on a single card, not a volume preference.
      const buckets = [
        {
          rows: rows.filter((row) => !SOCIAL_TYPES.has(row.notification_type)),
          cap: capFor(preferences),
          spent: spentByUser.get(userId) ?? 0,
          category: null as string | null,
        },
        {
          rows: rows.filter((row) => SOCIAL_TYPES.has(row.notification_type)),
          cap: SOCIAL_DAILY_PUSH_CAP,
          spent: socialSpentByUser.get(userId) ?? 0,
          category: 'social' as string | null,
        },
      ]

      for (const bucket of buckets) {
      if (bucket.rows.length === 0) continue

      const remaining = bucket.cap - bucket.spent

      if (remaining <= 0) {
        // Budget spent. Hold the rows — they are not lost, they go out (collapsed) once the
        // rolling window reopens, or get retired by the staleness rule if nobody cares by then.
        cappedCount += bucket.rows.length
        await supabaseClient
          .from('notifications')
          .update({ next_retry_at: new Date(Date.now() + 6 * 60 * 60 * 1000).toISOString() })
          .in('id', bucket.rows.map((row) => row.id))
        continue
      }

      // Within budget: each item keeps its own banner and its own deep link. Over budget: one
      // digest for the lot, which costs a single unit of budget. With an uncapped preference
      // `remaining` is Infinity, so this is never a digest.
      const asDigest = bucket.rows.length > remaining
      const batches = asDigest
        ? [{ payload: digestPayload(userId, bucket.rows, language), rows: bucket.rows }]
        : bucket.rows.map((row) => ({ payload: payloadForNotification(row, language), rows: [row] }))

      for (const batch of batches) {
        const result = await sendPush(
          supabaseClient,
          userId,
          batch.payload,
          firebaseAccessToken,
          firebaseServiceAccount.project_id
        )

        if (!result.sent) {
          await markFailed(batch.rows, result.error)
          continue
        }

        await markSent(batch.rows.map((row) => row.id))

        if (result.outcome === 'no-live-token') {
          // Nothing was delivered and nothing should be: no push, no email, no budget spent.
          silencedCount += batch.rows.length
          continue
        }

        if (result.outcome === 'never-registered') {
          // Email is the delivery here, not a duplicate of it.
          const { data: { user } } = await supabaseClient.auth.admin.getUserById(userId)
          if (user?.email) {
            const copy = asDigest
              ? { title: batch.payload.title, body: batch.payload.body }
              : localizedCopy(batch.rows[0], language)
            const document = renderFallbackEmail(language, copy)
            const outcome = await sendEmailWithBudget(supabaseClient, {
              userId,
              to: user.email,
              subject: document.subject,
              html: document.html,
              text: document.text,
              emailType: 'fallback',
              itemCount: batch.rows.length,
            }, { resendApiKey, fromEmail, spentToday: emailsSpentToday })
            if (outcome.sent) emailsSpentToday += 1
          }
          emailedCount += batch.rows.length
        } else {
          deliveredCount += batch.rows.length
        }

        if (asDigest) digestCount += 1
        // Logged for email too: the daily cap has to cover every channel, otherwise a user with
        // no device would receive an uncapped stream of mail.
        await supabaseClient.from('notification_delivery_log').insert({
          user_id: userId,
          kind: asDigest ? 'digest' : 'single',
          notification_count: batch.rows.length,
          category: bucket.category,
        })
      }
      }
    }

    if (expired.length > 0) {
      await supabaseClient
        .from('notifications')
        .update({ is_sent: true, sent_at: nowIso(), last_error: 'expired: older than 7 days' })
        .in('id', expired)
    }

    if (suppressedByPreferences.length > 0) {
      const { error: updateError } = await supabaseClient
        .from('notifications')
        .update({ is_sent: true, sent_at: nowIso(), last_error: null })
        .in('id', suppressedByPreferences)

      if (updateError) {
        throw new Error(`Error retiring suppressed notifications: ${updateError.message}`)
      }
    }

    if (skippedForQuietHours.length > 0) {
      await supabaseClient
        .from('notifications')
        .update({ next_retry_at: new Date(Date.now() + 60 * 60 * 1000).toISOString() })
        .in('id', skippedForQuietHours)
    }

    return new Response(
      JSON.stringify({
        message: 'Function executed.',
        fetched: notifications.length,
        delivered: deliveredCount,
        emailedFallback: emailedCount,
        silencedNoLiveToken: silencedCount,
        digests: digestCount,
        cappedForDailyLimit: cappedCount,
        expired: expired.length,
        suppressedByPreferences: suppressedByPreferences.length,
        quietHoursSkipped: skippedForQuietHours.length,
        stoppedOnDeadline,
      }),
      { headers: { 'Content-Type': 'application/json' }, status: 200 }
    )
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error)
    console.error('❌ process-notifications failed:', errorMessage)
    return new Response(JSON.stringify({ error: errorMessage }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
