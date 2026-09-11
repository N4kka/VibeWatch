// "It's on Netflix now" — the check itself, shared by the single-title endpoint and the daily
// sweep.
//
// It used to live inside check-availability, hardcoded to Italy: `results.IT` from TMDB, `IT`
// written to media_availability, and every subscriber notified about Italian platforms no matter
// where they were. Country is now a parameter, taken from the subscriber's own alert row, and
// the sweep groups its work by (title, country) so a title saved in two countries is checked
// once per country rather than once for Italy.
//
// The other invariant worth keeping: **one notification per user per title**, never one per
// provider. A title landing on Netflix, Prime and three rental stores used to queue five pushes
// for the same movie — the bulk of the 2026-07-22 burst.

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

const TMDB_API_URL = 'https://api.themoviedb.org/3'

type Provider = { provider_id: number; provider_name: string; logo_path?: string }

export type AvailabilityOutcome = {
  checked: boolean
  newProviders: number
  queued: number
  /** True when this (title, country) had no recorded state: providers were seeded, not announced. */
  seeded?: boolean
  reason?: string
}

export async function checkTitleAvailability(
  supabase: SupabaseClient,
  params: { mediaId: number; mediaType: string; countryCode: string; tmdbApiKey: string }
): Promise<AvailabilityOutcome> {
  const { mediaId, mediaType, countryCode, tmdbApiKey } = params

  const detailsRes = await fetch(
    `${TMDB_API_URL}/${mediaType}/${mediaId}?api_key=${tmdbApiKey}&language=en-US`
  )
  if (!detailsRes.ok) {
    return { checked: false, newProviders: 0, queued: 0, reason: `tmdb details ${detailsRes.status}` }
  }
  const details = await detailsRes.json()
  const mediaTitle: string = details.title || details.name || 'A media item'

  const providersRes = await fetch(
    `${TMDB_API_URL}/${mediaType}/${mediaId}/watch/providers?api_key=${tmdbApiKey}`
  )
  if (!providersRes.ok) {
    return { checked: false, newProviders: 0, queued: 0, reason: `tmdb providers ${providersRes.status}` }
  }
  const tmdbData = await providersRes.json()
  const countryProviders = tmdbData.results?.[countryCode]

  if (!countryProviders) {
    return { checked: true, newProviders: 0, queued: 0, reason: `no providers in ${countryCode}` }
  }

  const { data: storedAvailability, error: storedError } = await supabase
    .from('media_availability')
    .select('provider_id, availability_type')
    .eq('media_id', mediaId)
    .eq('media_type', mediaType)
    .eq('country_code', countryCode)

  if (storedError) throw storedError

  const storedProviders = new Set(
    (storedAvailability ?? []).map((p: { provider_id: string; availability_type: string }) =>
      `${p.provider_id}:${p.availability_type}`)
  )

  // **First sighting of this (title, country) is a baseline, not news.** "New" means a change
  // from a state we knew, not from no state at all: on a title nobody has ever checked, every
  // provider TMDB returns looks new, and a decade-old film would announce itself on all five
  // platforms it has always been on. Auto-enrollment made this urgent — it added 186 titles that
  // had never been looked at, and the first sweep would have been a push storm of exactly the
  // kind this pipeline already survived once. So: record what is there, tell nobody, and let the
  // next run compare against it.
  const isFirstSighting = storedProviders.size === 0

  const newProviders: (Provider & { type: string })[] = []
  const availabilityToUpsert: Record<string, unknown>[] = []

  const processProviders = (providers: Provider[] | undefined, type: 'stream' | 'rent' | 'buy') => {
    if (!providers) return
    for (const provider of providers) {
      if (!storedProviders.has(`${provider.provider_id}:${type}`)) {
        newProviders.push({ ...provider, type })
      }
      availabilityToUpsert.push({
        media_id: mediaId,
        media_type: mediaType,
        provider_id: provider.provider_id.toString(),
        provider_name: provider.provider_name,
        country_code: countryCode,
        availability_type: type,
        web_url: countryProviders.link,
        last_checked_at: new Date().toISOString(),
      })
    }
  }

  processProviders(countryProviders.flatrate, 'stream')
  processProviders(countryProviders.rent, 'rent')
  processProviders(countryProviders.buy, 'buy')

  let queued = 0

  if (newProviders.length > 0 && !isFirstSighting) {
    const { data: users, error: usersError } = await supabase
      .from('release_alerts')
      .select('user_id, alert_on_stream, alert_on_rent, alert_on_buy')
      .eq('media_id', mediaId)
      .eq('media_type', mediaType)
      .eq('country_code', countryCode)
      .eq('is_active', true)
      .is('deleted_at', null)

    if (usersError) throw usersError

    const notificationsToInsert = []
    for (const user of users ?? []) {
      const wanted = newProviders.filter((provider) =>
        (provider.type === 'stream' && user.alert_on_stream) ||
        (provider.type === 'rent' && user.alert_on_rent) ||
        (provider.type === 'buy' && user.alert_on_buy)
      )

      if (wanted.length === 0) continue

      // Streaming is the headline when it's there; otherwise lead with whatever came in.
      const headline = wanted.find((provider) => provider.type === 'stream') ?? wanted[0]
      const others = wanted.length - 1

      notificationsToInsert.push({
        user_id: user.user_id,
        media_id: mediaId,
        media_type: mediaType,
        // English fallback; the dispatcher renders template_key in the reader's language.
        title: `${mediaTitle} is now available!`,
        body: others > 0
          ? `It's now available to ${headline.type} on ${headline.provider_name} and ${others} more.`
          : `It's now available to ${headline.type} on ${headline.provider_name}.`,
        notification_type: 'new_availability',
        category: 'new_availability',
        thread_id: `availability:${mediaType}:${mediaId}`,
        template_key: 'new_availability',
        template_params: {
          title: mediaTitle,
          provider: headline.provider_name,
          kind: headline.type,
          count: others,
        },
      })
    }

    if (notificationsToInsert.length > 0) {
      const { error: notificationError } = await supabase
        .from('notifications')
        .insert(notificationsToInsert)
      if (notificationError) throw notificationError
      queued = notificationsToInsert.length
    }
  }

  if (availabilityToUpsert.length > 0) {
    const { error } = await supabase.from('media_availability').upsert(availabilityToUpsert, {
      onConflict: 'media_id,media_type,provider_id,country_code,availability_type',
    })
    if (error) throw error
  }

  return { checked: true, newProviders: newProviders.length, queued, seeded: isFirstSighting }
}
