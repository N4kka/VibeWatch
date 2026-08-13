import { assertEquals, assertStringIncludes } from 'https://deno.land/std@0.208.0/assert/mod.ts'
import {
  capFor,
  DEFAULT_DAILY_PUSH_CAP,
  digestPayload,
  isInQuietHours,
  NotificationPreferences,
  NotificationRow,
  payloadForNotification,
  preferenceAllows,
  retryDelayMinutes,
} from './logic.ts'

function prefs(overrides: Partial<NotificationPreferences> = {}): NotificationPreferences {
  return {
    push_enabled: true,
    new_availability: true,
    new_release: true,
    episode_aired: true,
    continue_watching: true,
    streak_reminder: false,
    new_follower: true,
    activity_liked: true,
    activity_commented: true,
    max_daily_notifications: 2,
    quiet_hours_start: null,
    quiet_hours_end: null,
    timezone: null,
    language: 'en',
    ...overrides,
  }
}

function row(overrides: Partial<NotificationRow> = {}): NotificationRow {
  return {
    id: 'row-1',
    user_id: 'user-1',
    notification_type: 'new_release',
    title: 'New release',
    body: 'Dune is out now.',
    ...overrides,
  }
}

Deno.test('the preference gate reads the mapped column, not the type name', () => {
  assertEquals(preferenceAllows(row(), prefs()), true)
  assertEquals(preferenceAllows(row(), prefs({ new_release: false })), false)
})

Deno.test('push_enabled = false silences everything', () => {
  assertEquals(preferenceAllows(row(), prefs({ push_enabled: false })), false)
  assertEquals(
    preferenceAllows(row({ notification_type: 'import_done' }), prefs({ push_enabled: false })),
    false
  )
})

Deno.test('import_done has no switch: an import the user started always reports back', () => {
  assertEquals(
    preferenceAllows(row({ notification_type: 'import_done' }), prefs({ new_release: false })),
    true
  )
})

Deno.test('a user with no preferences row receives everything', () => {
  assertEquals(preferenceAllows(row(), null), true)
})

Deno.test('an unmapped type is allowed rather than silently dropped', () => {
  assertEquals(preferenceAllows(row({ notification_type: 'invented_type' }), prefs()), true)
})

Deno.test('streak reminders are off unless the user opted in', () => {
  const streak = row({ notification_type: 'streak_reminder' })
  assertEquals(preferenceAllows(streak, prefs()), false)
  assertEquals(preferenceAllows(streak, prefs({ streak_reminder: true })), true)
})

Deno.test('capFor: absent preference falls back to the historical cap', () => {
  assertEquals(capFor(null), DEFAULT_DAILY_PUSH_CAP)
  assertEquals(capFor(prefs({ max_daily_notifications: null })), DEFAULT_DAILY_PUSH_CAP)
})

Deno.test('capFor: 0 means uncapped, so nothing is ever collapsed into a digest', () => {
  assertEquals(capFor(prefs({ max_daily_notifications: 0 })), Number.POSITIVE_INFINITY)
  // The dispatcher's own arithmetic: rows.length > remaining is what triggers a digest.
  const remaining = capFor(prefs({ max_daily_notifications: 0 })) - 3
  assertEquals(20 > remaining, false)
})

Deno.test('capFor: the Balanced preset is honoured verbatim', () => {
  assertEquals(capFor(prefs({ max_daily_notifications: 5 })), 5)
})

Deno.test('quiet hours wrap across midnight', () => {
  const night = prefs({ quiet_hours_start: '22:00:00', quiet_hours_end: '08:00:00', timezone: 'UTC' })
  assertEquals(isInQuietHours(night, new Date('2026-08-14T23:30:00Z')), true)
  assertEquals(isInQuietHours(night, new Date('2026-08-14T03:00:00Z')), true)
  assertEquals(isInQuietHours(night, new Date('2026-08-14T12:00:00Z')), false)
})

Deno.test('quiet hours are off when start equals end, and when the timezone is unknown', () => {
  assertEquals(
    isInQuietHours(prefs({ quiet_hours_start: '08:00:00', quiet_hours_end: '08:00:00', timezone: 'UTC' })),
    false
  )
  assertEquals(
    isInQuietHours(prefs({ quiet_hours_start: '22:00:00', quiet_hours_end: '08:00:00', timezone: null })),
    false
  )
})

Deno.test('the banner is rendered in the user language when the row carries a template', () => {
  const payload = payloadForNotification(
    row({ template_key: 'new_release', template_params: { title: 'Dune' } }),
    'it'
  )
  assertEquals(payload.title, 'Nuova uscita')
  assertEquals(payload.body, 'Dune è uscito.')
})

Deno.test('a legacy row without a template keeps the English copy its producer stored', () => {
  const payload = payloadForNotification(row(), 'it')
  assertEquals(payload.title, 'New release')
  assertEquals(payload.body, 'Dune is out now.')
})

Deno.test('a digest of one type names that type, in the user language', () => {
  const rows = [row(), row({ id: 'row-2' }), row({ id: 'row-3' })]
  const payload = digestPayload('user-1', rows, 'it')
  assertEquals(payload.body, '3 titoli della tua lista sono usciti.')
  assertEquals(payload.mediaId, null) // no deep link into an arbitrary collapsed item
  assertEquals(payload.collapseId, 'digest:user-1')
})

Deno.test('a digest of mixed social types says so instead of falling back to "updates"', () => {
  const rows = [
    row({ id: 'a', notification_type: 'activity_liked' }),
    row({ id: 'b', notification_type: 'new_follower' }),
  ]
  assertStringIncludes(digestPayload('user-1', rows, 'en').body, 'people interacted with you')
})

Deno.test('a digest of unrelated types falls back to the generic line', () => {
  const rows = [
    row({ id: 'a', notification_type: 'new_release' }),
    row({ id: 'b', notification_type: 'import_done' }),
  ]
  assertStringIncludes(digestPayload('user-1', rows, 'en').body, '2 new updates')
})

Deno.test('retry backoff doubles and stops at an hour', () => {
  assertEquals(retryDelayMinutes(0), 1)
  assertEquals(retryDelayMinutes(3), 8)
  assertEquals(retryDelayMinutes(20), 60)
})
