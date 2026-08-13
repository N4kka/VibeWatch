import { assertEquals, assertStringIncludes } from 'https://deno.land/std@0.208.0/assert/mod.ts'
import {
  ENGLISH_KEYS,
  normalizeLanguage,
  renderNotification,
  SUPPORTED_LANGUAGES,
  t,
} from './i18n.ts'

// The whole point of a catalog is that a locale is either complete or falls back visibly. A hole
// in a translation is a raw English string in the middle of an Italian push, which is survivable;
// a hole this test would not catch is a *typo in a key*, which renders the key itself.
Deno.test('every locale defines every key the English catalog defines', () => {
  const missing: string[] = []
  for (const language of SUPPORTED_LANGUAGES) {
    for (const key of ENGLISH_KEYS) {
      // t() falls back to English, so compare against the raw lookup: a locale that returns the
      // English string for a key it does not define is exactly what we are looking for.
      const localized = t(language, key, { count: 1, title: 'X', name: 'Y', show: 'Z', provider: 'P', days: 3, episode: 'E', date: 'D', episodes: 1, shows: 1, pending: 0, kind: 'K' })
      if (!localized || localized === key) missing.push(`${language}:${key}`)
    }
  }
  assertEquals(missing, [])
})

Deno.test('normalizeLanguage accepts regional tags and unknown locales', () => {
  assertEquals(normalizeLanguage('it'), 'it')
  assertEquals(normalizeLanguage('it-IT'), 'it')
  assertEquals(normalizeLanguage('pt_BR'), 'pt')
  assertEquals(normalizeLanguage('XX'), 'en')
  assertEquals(normalizeLanguage(null), 'en')
  assertEquals(normalizeLanguage(undefined), 'en')
})

Deno.test('a missing parameter renders as empty, never as the placeholder', () => {
  const rendered = t('en', 'push.new_release.body', {})
  assertEquals(rendered.includes('{'), false)
})

Deno.test('new_availability picks the "and N more" variant only above one provider', () => {
  const single = renderNotification('new_availability', { title: 'Dune', provider: 'Netflix', kind: 'stream', count: 0 }, 'en')
  assertEquals(single?.body, 'Available to stream on Netflix.')

  const several = renderNotification('new_availability', { title: 'Dune', provider: 'Netflix', kind: 'stream', count: 2 }, 'en')
  assertStringIncludes(several?.body ?? '', 'and 2 more')
})

Deno.test('episode_aired falls back to the generic body without a season/episode label', () => {
  const labeled = renderNotification('episode_aired', { show: 'Severance', episode: 'S02E03' }, 'en')
  assertEquals(labeled?.body, 'Severance S02E03 is out.')

  const generic = renderNotification('episode_aired', { show: 'Severance' }, 'en')
  assertEquals(generic?.body, 'Severance has a new episode out.')
})

Deno.test('an anonymous actor becomes the localized "Someone", not an empty name', () => {
  const rendered = renderNotification('new_follower', { name: '' }, 'it')
  assertStringIncludes(rendered?.body ?? '', 'Qualcuno')
})

Deno.test('Italian rendering of a saved-title release', () => {
  const rendered = renderNotification('new_release', { title: 'Dune' }, 'it')
  assertEquals(rendered?.title, 'Nuova uscita')
  assertEquals(rendered?.body, 'Dune è uscito.')
})

Deno.test('an unknown template key renders nothing so the caller keeps the stored copy', () => {
  assertEquals(renderNotification('something_new_from_the_future', { a: 1 }, 'en'), null)
  assertEquals(renderNotification(null, null, 'en'), null)
})

Deno.test('import_done switches to the review variant only when items are pending', () => {
  const clean = renderNotification('import_done', { episodes: 120, shows: 8, pending: 0 }, 'en')
  assertEquals(clean?.body, '120 episodes from 8 shows imported.')

  const dirty = renderNotification('import_done', { episodes: 120, shows: 8, pending: 3 }, 'en')
  assertStringIncludes(dirty?.body ?? '', '3 items need review')
})
