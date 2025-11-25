import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const TMDB_API_KEY = 'e42f888f287ca2fbe26c9a6e70351fb7'
const TMDB_API_URL = 'https://api.themoviedb.org/3'

interface Provider {
  provider_id: number
  provider_name: string
  logo_path: string
}

interface WatchProviderResult {
  link: string
  flatrate?: Provider[]
  rent?: Provider[]
  buy?: Provider[]
}

interface TMDBWatchProviderResponse {
  id: number
  results: {
    [countryCode: string]: WatchProviderResult
  }
}

interface MediaDetails {
  title?: string // For movies
  name?: string // For TV shows
}

serve(async (req) => {
  try {
    const { mediaId, mediaType } = await req.json()

    if (!mediaId || !mediaType) {
      return new Response(JSON.stringify({ error: 'mediaId and mediaType are required' }), {
        headers: { 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // --- FETCH MEDIA DETAILS (FOR TITLE) ---
    const detailsUrl = `${TMDB_API_URL}/${mediaType}/${mediaId}?api_key=${TMDB_API_KEY}&language=en-US`
    const detailsRes = await fetch(detailsUrl)
    if (!detailsRes.ok) {
      throw new Error(`TMDB API request for details failed with status ${detailsRes.status}`)
    }
    const detailsData: MediaDetails = await detailsRes.json()
    const mediaTitle = detailsData.title || detailsData.name || 'A media item'

    // --- FETCH WATCH PROVIDERS ---
    const providersUrl = `${TMDB_API_URL}/${mediaType}/${mediaId}/watch/providers?api_key=${TMDB_API_KEY}`
    const providersRes = await fetch(providersUrl)

    if (!providersRes.ok) {
      throw new Error(`TMDB API request for providers failed with status ${providersRes.status}`)
    }

    const tmdbData: TMDBWatchProviderResponse = await providersRes.json()
    const itProviders = tmdbData.results?.IT

    if (!itProviders) {
      return new Response(JSON.stringify({ message: 'No providers found for Italy' }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }
    
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // 1. Get previously stored availability
    const { data: storedAvailability, error: storedError } = await supabase
      .from('media_availability')
      .select('provider_id, availability_type')
      .eq('media_id', mediaId)
      .eq('media_type', mediaType)
      .eq('country_code', 'IT')

    if (storedError) throw storedError

    const storedProviders = new Set(
      storedAvailability.map((p) => `${p.provider_id}:${p.availability_type}`)
    )

    // 2. Process newly fetched availability and identify new platforms
    const newProviders: (Provider & { type: string })[] = []
    const availabilityToUpsert = []

    const processProviders = (providers: Provider[], type: 'stream' | 'rent' | 'buy') => {
      if (!providers) return
      for (const provider of providers) {
        const providerKey = `${provider.provider_id}:${type}`
        // If the provider is not in our stored set, it's new
        if (!storedProviders.has(providerKey)) {
          newProviders.push({ ...provider, type })
        }
        availabilityToUpsert.push({
          media_id: mediaId,
          media_type: mediaType,
          provider_id: provider.provider_id.toString(),
          provider_name: provider.provider_name,
          country_code: 'IT',
          availability_type: type,
          web_url: itProviders.link,
          last_checked_at: new Date().toISOString(),
        })
      }
    }
    
    processProviders(itProviders.flatrate, 'stream')
    processProviders(itProviders.rent, 'rent')
    processProviders(itProviders.buy, 'buy')

    // 3. If new providers are found, find users who want alerts and queue notifications
    if (newProviders.length > 0) {
      const { data: users, error: usersError } = await supabase
        .from('release_alerts')
        .select('user_id, alert_on_stream, alert_on_rent, alert_on_buy')
        .eq('media_id', mediaId)
        .eq('media_type', mediaType)
        .eq('is_active', true)

      if (usersError) throw usersError

      if (users && users.length > 0) {
        const notificationsToInsert = []
        for (const user of users) {
          for (const provider of newProviders) {
            // Check if user wants alerts for this availability type
            const wantsAlert = 
              (provider.type === 'stream' && user.alert_on_stream) ||
              (provider.type === 'rent' && user.alert_on_rent) ||
              (provider.type === 'buy' && user.alert_on_buy)

            if (wantsAlert) {
              notificationsToInsert.push({
                user_id: user.user_id,
                media_id: mediaId,
                media_type: mediaType,
                title: `${mediaTitle} is now available!`,
                body: `It's now available to ${provider.type} on ${provider.provider_name}.`,
                notification_type: 'new_availability',
              })
            }
          }
        }

        if (notificationsToInsert.length > 0) {
          const { error: notificationError } = await supabase
            .from('notifications')
            .insert(notificationsToInsert)
          
          if (notificationError) throw notificationError
        }
      }
    }
    
    // 4. Upsert the complete and current availability list
    if (availabilityToUpsert.length > 0) {
      const { error } = await supabase.from('media_availability').upsert(availabilityToUpsert, {
        onConflict: 'media_id,media_type,provider_id,country_code,availability_type',
      })
      if (error) {
        throw error
      }
    }

    const responseMessage = newProviders.length > 0 
      ? `Availability checked. Found ${newProviders.length} new providers and queued notifications.`
      : 'Availability checked. No new providers found.'

    return new Response(JSON.stringify({ message: responseMessage, newProviders }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
