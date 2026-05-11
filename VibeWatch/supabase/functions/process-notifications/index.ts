import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { SignJWT, importPKCS8 } from 'https://esm.sh/jose@v5.2.3'

console.log('🚀 process-notifications function booting up...')

type NotificationRow = {
  id: string
  user_id: string
  notification_type: string
  title: string
  body: string
  media_id?: number | string | null
  media_type?: string | null
  retry_count?: number | null
  category?: string | null
  thread_id?: string | null
}

type NotificationPreferences = {
  push_enabled: boolean
  new_availability: boolean
  new_release: boolean
  episode_aired: boolean
  streak_reminder: boolean
  list_milestone: boolean
  price_drop: boolean
  quiet_hours_start: string | null
  quiet_hours_end: string | null
  timezone: string | null
}

type PushResult = {
  sent: boolean
  retryable: boolean
  permanent: boolean
  error?: string
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

function preferenceAllows(notification: NotificationRow, preferences?: NotificationPreferences | null) {
  if (!preferences) return true
  if (!preferences.push_enabled) return false

  const key = notification.notification_type as keyof NotificationPreferences
  const value = preferences[key]
  return typeof value === 'boolean' ? value : true
}

function localTimeParts(timezone: string) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(new Date())

  const hour = Number(parts.find((part) => part.type === 'hour')?.value ?? '0')
  const minute = Number(parts.find((part) => part.type === 'minute')?.value ?? '0')
  return hour * 60 + minute
}

function parseHHMM(value: string) {
  const [hour, minute] = value.split(':').map((part) => Number(part))
  return hour * 60 + minute
}

function isInQuietHours(preferences?: NotificationPreferences | null) {
  if (!preferences?.quiet_hours_start || !preferences?.quiet_hours_end || !preferences.timezone) {
    return false
  }

  const now = localTimeParts(preferences.timezone)
  const start = parseHHMM(preferences.quiet_hours_start)
  const end = parseHHMM(preferences.quiet_hours_end)

  if (start === end) return false
  if (start < end) return now >= start && now < end
  return now >= start || now < end
}

function classifyFcmError(status: number, body: string): PushResult {
  const permanent = body.includes('UNREGISTERED') || body.includes('INVALID_ARGUMENT')
  const retryable = status === 429 || status >= 500
  return {
    sent: false,
    permanent,
    retryable: !permanent && retryable,
    error: body,
  }
}

function retryDelayMinutes(retryCount: number) {
  return Math.min(60, Math.pow(2, Math.max(0, retryCount))) // 1,2,4... max 60 min
}

async function sendPushNotification(
  supabaseClient: SupabaseClient,
  notification: NotificationRow,
  accessToken: string,
  projectId: string
): Promise<PushResult> {
  const { data: devices, error: deviceError } = await supabaseClient
    .from('user_devices')
    .select('fcm_token')
    .eq('user_id', notification.user_id)
    .not('fcm_token', 'is', null)

  if (deviceError) {
    return { sent: false, retryable: true, permanent: false, error: deviceError.message }
  }

  if (!devices || devices.length === 0) {
    return { sent: true, retryable: false, permanent: false }
  }

  let sawRetryable = false
  let sawPermanent = false
  let lastError: string | undefined

  for (const device of devices) {
    const fcmToken = device.fcm_token
    const collapseId = `${notification.notification_type}:${notification.media_type ?? 'none'}:${notification.media_id ?? notification.id}`
    const priority = notification.notification_type === 'streak_reminder' ? '5' : '10'

    const message = {
      message: {
        token: fcmToken,
        notification: {
          title: notification.title,
          body: notification.body,
        },
        data: {
          notification_id: String(notification.id),
          notification_type: notification.notification_type,
          media_id: String(notification.media_id ?? ''),
          media_type: String(notification.media_type ?? ''),
        },
        apns: {
          headers: {
            'apns-priority': priority,
            'apns-collapse-id': collapseId,
          },
          payload: {
            aps: {
              sound: 'default',
              badge: 1,
              category: notification.category ?? notification.notification_type,
              'thread-id': notification.thread_id ?? notification.notification_type,
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
  }
}

async function sendEmail(
  supabaseClient: SupabaseClient,
  notification: NotificationRow,
  resendApiKey: string,
  fromEmail: string
) {
  const { data: { user }, error: userError } = await supabaseClient.auth.admin.getUserById(notification.user_id)
  if (userError || !user?.email) return

  await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${resendApiKey}`,
    },
    body: JSON.stringify({
      from: fromEmail,
      to: user.email,
      subject: notification.title,
      html: `<p>${notification.body}</p><p>Log in to VibeWatch to see more.</p>`,
    }),
  })
}

serve(async (_req) => {
  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const firebaseServiceAccountJson = Deno.env.get('FIREBASE_SERVICE_ACCOUNT')
    const resendApiKey = Deno.env.get('RESEND_API_KEY')
    const fromEmail = Deno.env.get('FROM_EMAIL')

    if (!firebaseServiceAccountJson || !resendApiKey || !fromEmail) {
      throw new Error('Missing required environment variables/secrets.')
    }

    const firebaseServiceAccount = JSON.parse(firebaseServiceAccountJson)

    const { data: notifications, error: fetchError } = await supabaseClient
      .from('notifications')
      .select('*')
      .eq('is_sent', false)
      .or(`next_retry_at.is.null,next_retry_at.lte.${new Date().toISOString()}`)
      .limit(100)

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
    const sentNotificationIds: string[] = []
    const skippedForQuietHours: string[] = []

    for (const notification of notifications as NotificationRow[]) {
      const preferences = preferencesByUser.get(notification.user_id)

      if (!preferenceAllows(notification, preferences)) {
        sentNotificationIds.push(notification.id)
        continue
      }

      if (isInQuietHours(preferences)) {
        skippedForQuietHours.push(notification.id)
        continue
      }

      const result = await sendPushNotification(
        supabaseClient,
        notification,
        firebaseAccessToken,
        firebaseServiceAccount.project_id
      )

      if (result.sent) {
        await sendEmail(supabaseClient, notification, resendApiKey, fromEmail)
        sentNotificationIds.push(notification.id)
      } else {
        const retryCount = (notification.retry_count ?? 0) + 1
        const nextRetryAt = new Date(Date.now() + retryDelayMinutes(retryCount) * 60 * 1000).toISOString()
        await supabaseClient
          .from('notifications')
          .update({
            retry_count: retryCount,
            next_retry_at: nextRetryAt,
            last_error: result.error ?? 'unknown push failure',
          })
          .eq('id', notification.id)
      }
    }

    if (sentNotificationIds.length > 0) {
      const { error: updateError } = await supabaseClient
        .from('notifications')
        .update({ is_sent: true, sent_at: new Date().toISOString(), last_error: null })
        .in('id', sentNotificationIds)

      if (updateError) {
        throw new Error(`Error marking notifications as sent: ${updateError.message}`)
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
        processed: notifications.length,
        sent: sentNotificationIds.length,
        quietHoursSkipped: skippedForQuietHours.length,
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
