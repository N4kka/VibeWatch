// The dispatcher's decisions, separated from the network.
//
// Everything here is a pure function of a queue row and a preferences row: whether a
// notification is allowed, how much of the user's daily budget is left, what the collapsed
// digest says, what the banner reads in the user's language. Keeping them out of index.ts is
// what makes them testable without a Firebase service account and a live database.

import { t } from '../_shared/i18n.ts'
import { localizedCopy, NotificationRow } from '../_shared/notificationCopy.ts'

export type { NotificationRow }
export { localizedCopy }

export type NotificationPreferences = {
  push_enabled: boolean
  new_availability: boolean
  new_release: boolean
  episode_aired: boolean
  continue_watching: boolean
  streak_reminder: boolean
  new_follower: boolean
  activity_liked: boolean
  activity_commented: boolean
  max_daily_notifications: number | null
  quiet_hours_start: string | null
  quiet_hours_end: string | null
  timezone: string | null
  language: string | null
}

export type PushPayload = {
  dataId: string
  notificationType: string
  title: string
  body: string
  mediaId?: number | string | null
  mediaType?: string | null
  category: string
  threadId: string
  collapseId: string
}

// The three types whose budget is counted separately.
export const SOCIAL_TYPES = new Set(['new_follower', 'activity_liked', 'activity_commented'])

// Follows, likes and comments are the strongest re-engagement signal the app has, and they are
// rare by construction — a user gets a handful a week, not a stream. They are delivered singly;
// the cap exists only so a card that suddenly collects fifty likes cannot become fifty banners.
export const SOCIAL_DAILY_PUSH_CAP = 10

// The general cap when the user has expressed no preference. Matches the old hardcoded value.
export const DEFAULT_DAILY_PUSH_CAP = 2

// Which preferences column gates which type. This used to be `preferences[notification_type]`,
// which silently depended on the column being named exactly like the type — adding a type with a
// mismatched name would have made it un-mutable rather than raising anything. `null` marks a
// type with no switch: an import finishing is the answer to something the user started.
export const PREF_COLUMN_BY_TYPE: Record<string, keyof NotificationPreferences | null> = {
  new_availability: 'new_availability',
  new_release: 'new_release',
  episode_aired: 'episode_aired',
  continue_watching: 'continue_watching',
  streak_reminder: 'streak_reminder',
  new_follower: 'new_follower',
  activity_liked: 'activity_liked',
  activity_commented: 'activity_commented',
  import_done: null,
}

export function preferenceAllows(
  notification: NotificationRow,
  preferences?: NotificationPreferences | null
): boolean {
  if (!preferences) return true
  if (!preferences.push_enabled) return false

  const column = PREF_COLUMN_BY_TYPE[notification.notification_type]
  if (column === null) return true
  if (column === undefined) {
    console.warn(`[process-notifications] no preference mapping for '${notification.notification_type}', allowing`)
    return true
  }

  const value = preferences[column]
  return typeof value === 'boolean' ? value : true
}

/**
 * How many pushes this user accepts in a rolling 24h window. 0 means "no cap": returning
 * Infinity keeps the caller's arithmetic honest — `remaining` never reaches zero, so nothing is
 * ever collapsed into a digest and every notification keeps its own banner and deep link.
 */
export function capFor(preferences?: NotificationPreferences | null): number {
  const configured = preferences?.max_daily_notifications
  if (configured === null || configured === undefined) return DEFAULT_DAILY_PUSH_CAP
  return configured === 0 ? Number.POSITIVE_INFINITY : configured
}

export function localTimeParts(timezone: string, now: Date = new Date()): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(now)

  const hour = Number(parts.find((part) => part.type === 'hour')?.value ?? '0')
  const minute = Number(parts.find((part) => part.type === 'minute')?.value ?? '0')
  return hour * 60 + minute
}

function parseHHMM(value: string): number {
  const [hour, minute] = value.split(':').map((part) => Number(part))
  return hour * 60 + minute
}

export function isInQuietHours(preferences?: NotificationPreferences | null, now: Date = new Date()): boolean {
  if (!preferences?.quiet_hours_start || !preferences?.quiet_hours_end || !preferences.timezone) {
    return false
  }

  const current = localTimeParts(preferences.timezone, now)
  const start = parseHHMM(preferences.quiet_hours_start)
  const end = parseHHMM(preferences.quiet_hours_end)

  if (start === end) return false
  if (start < end) return current >= start && current < end
  return current >= start || current < end
}

export function classifyFcmError(status: number, body: string) {
  const permanent = body.includes('UNREGISTERED') || body.includes('INVALID_ARGUMENT')
  const retryable = status === 429 || status >= 500
  return { permanent, retryable: !permanent && retryable, error: body }
}

export function retryDelayMinutes(retryCount: number): number {
  return Math.min(60, Math.pow(2, Math.max(0, retryCount))) // 1,2,4... max 60 min
}

export function payloadForNotification(
  notification: NotificationRow,
  language: string | null | undefined
): PushPayload {
  const copy = localizedCopy(notification, language)
  return {
    dataId: String(notification.id),
    notificationType: notification.notification_type,
    title: copy.title,
    body: copy.body,
    mediaId: notification.media_id,
    mediaType: notification.media_type,
    category: notification.category ?? notification.notification_type,
    threadId: notification.thread_id ?? notification.notification_type,
    collapseId: `${notification.notification_type}:${notification.media_type ?? 'none'}:${notification.media_id ?? notification.id}`,
  }
}

/** Dove atterra chi tocca la notifica sul web. Il default e' l'indirizzo di produzione. */
export const WEB_APP_ORIGIN = 'https://vibewatchapp.com'

/**
 * L'equivalente web del deep link che su iOS e' `notification_type` + `media_id`.
 *
 * Su iOS il client interpreta i `data` e decide dove andare; un browser non ha quel client,
 * ha un URL: `webpush.fcm_options.link` e' l'unico posto dove la destinazione puo' essere
 * scritta, e la scrive il mittente. Le rotte qui sono quelle di `app/routes.ts` del sito, non
 * un indovinello: un percorso sbagliato non fallisce, apre la pagina "qui non c'e' niente".
 *
 * Quando la notifica non ha un media (digest, streak, social) si va sulla schermata che la
 * riguarda, mai su uno dei titoli accorpati scelto a caso.
 */
export function webLink(payload: PushPayload, origin: string = WEB_APP_ORIGIN): string {
  const type = payload.notificationType

  if (SOCIAL_TYPES.has(type)) return `${origin}/social`
  if (type === 'streak_reminder') return `${origin}/gamification`
  if (type === 'import_done') return `${origin}/import`

  const mediaId = payload.mediaId
  if (mediaId !== null && mediaId !== undefined && String(mediaId).length > 0) {
    const mediaType = String(payload.mediaType ?? '').toLowerCase()
    if (mediaType === 'movie' || mediaType === 'film') return `${origin}/film/${mediaId}`
    if (mediaType === 'tv' || mediaType === 'show' || mediaType === 'series') {
      return `${origin}/show/${mediaId}`
    }
  }

  // Digest, tipi senza media, tipi nuovi non ancora mappati: la home dell'app.
  return `${origin}/discover`
}

const DIGEST_KEY_BY_TYPE: Record<string, string> = {
  new_release: 'digest.new_release',
  new_availability: 'digest.new_availability',
  episode_aired: 'digest.episode_aired',
  continue_watching: 'digest.continue_watching',
  new_follower: 'digest.new_follower',
}

/**
 * One push standing in for several queued rows. It carries no media_id on purpose: the client
 * falls back to the Discovery tab rather than deep-linking into an arbitrary one of the
 * collapsed items.
 */
export function digestPayload(
  userId: string,
  rows: NotificationRow[],
  language: string | null | undefined
): PushPayload {
  const types = new Set(rows.map((row) => row.notification_type))
  const singleType = types.size === 1 ? [...types][0] : null
  const allSocial = rows.every((row) => SOCIAL_TYPES.has(row.notification_type))

  const key = (singleType && DIGEST_KEY_BY_TYPE[singleType])
    ?? (allSocial ? 'digest.social' : 'digest.generic')

  return {
    dataId: rows[0].id,
    notificationType: singleType ?? 'digest',
    title: t(language, 'digest.title'),
    body: t(language, key, { count: rows.length }),
    mediaId: null,
    mediaType: null,
    category: 'digest',
    threadId: 'digest',
    collapseId: `digest:${userId}`,
  }
}
