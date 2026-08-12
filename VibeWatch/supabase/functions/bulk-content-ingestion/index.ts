// Bulk Content Ingestion Edge Function
// Purpose: Fetch 5,000 YouTube clips + 2,500 movies/TV shows across 10 countries
// Author: VibeWatch Engineering
// Version: 1.0.0

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'

// Country distribution targets
const COUNTRY_TARGETS = [
  { code: 'US', language: 'en', clips: 800, content: 250 },
  { code: 'IT', language: 'it', clips: 500, content: 250 },
  { code: 'GB', language: 'en', clips: 600, content: 250 },
  { code: 'CA', language: 'en', clips: 400, content: 250 },
  { code: 'FR', language: 'fr', clips: 500, content: 250 },
  { code: 'DE', language: 'de', clips: 500, content: 250 },
  { code: 'ES', language: 'es', clips: 500, content: 250 },
  { code: 'MX', language: 'es', clips: 400, content: 250 },
  { code: 'BR', language: 'pt', clips: 400, content: 250 },
  { code: 'AU', language: 'en', clips: 400, content: 250 },
]

// YouTube API configuration
const YOUTUBE_API_KEY = Deno.env.get('YOUTUBE_API_KEY') || 'AIzaSyCh_tkrvBEGW6ALRvkAN-LYx1B3Cly1160'
const YOUTUBE_API_BASE = 'https://www.googleapis.com/youtube/v3'

// Rate limiting delays
const TMDB_DELAY_MS = 250
const YOUTUBE_DELAY_MS = 100

// Content distribution (per country)
const CONTENT_MIX = {
  trendingMovies: 0.60,  // 150 items
  popularMovies: 0.20,   // 50 items
  topRatedMovies: 0.10,  // 25 items
  trendingTV: 0.10,      // 25 items
}

interface TMDBMovie {
  id: number
  title: string
  overview: string
  poster_path: string | null
  backdrop_path: string | null
  release_date: string
  vote_average: number
  genre_ids: number[]
}

interface TMDBTVShow {
  id: number
  name: string
  overview: string
  poster_path: string | null
  backdrop_path: string | null
  first_air_date: string
  vote_average: number
  genre_ids: number[]
}

interface YouTubeVideo {
  id: string
  title: string
  description: string
  thumbnailUrl: string
  duration: number
  embeddable: boolean
  publicAccess: boolean
}

interface IngestionStats {
  country: string
  contentFetched: number
  clipsFetched: number
  clipsStored: number
  errors: number
  startTime: number
}

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  try {
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceKey = (() => {
      const s = Deno.env.get('SUPABASE_SECRET_KEYS')
      if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
      return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    })()
    const tmdbApiKey = Deno.env.get('TMDB_API_KEY')

    if (!tmdbApiKey) {
      return new Response(
        JSON.stringify({ error: 'TMDB_API_KEY environment variable not set' }),
        { status: 500, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // Parse request body for optional parameters
    const body = await req.json().catch(() => ({}))
    const testMode = body.testMode || false
    const targetCountry = body.country || null

    console.log('Starting bulk content ingestion...')
    console.log(`Test mode: ${testMode}`)
    console.log(`Target country: ${targetCountry || 'All countries'}`)

    const stats: IngestionStats[] = []
    const countries = targetCountry
      ? COUNTRY_TARGETS.filter(c => c.code === targetCountry)
      : COUNTRY_TARGETS

    // Process each country
    for (const country of countries) {
      const countryStats: IngestionStats = {
        country: country.code,
        contentFetched: 0,
        clipsFetched: 0,
        clipsStored: 0,
        errors: 0,
        startTime: Date.now(),
      }

      console.log(`\n=== Processing ${country.code} (${country.language}) ===`)

      try {
        // ========================================
        // OPTION 1: Fetch NEW content from TMDb (COMMENTED OUT - using existing data)
        // ========================================
        // const tmdbContent = await fetchTMDbContent(
        //   tmdbApiKey,
        //   country.code,
        //   country.language,
        //   testMode ? 10 : country.content
        // )
        // countryStats.contentFetched = tmdbContent.length
        // console.log(`Fetched ${tmdbContent.length} TMDb items for ${country.code}`)

        // // Store TMDb content in discovery_cache table
        // for (const item of tmdbContent) {
        //   await storeTMDbContent(supabase, item, country.code)
        //   await delay(50)
        // }

        // ========================================
        // OPTION 2: Use EXISTING content from discovery_cache (ACTIVE)
        // ========================================
        console.log(`Fetching existing content from discovery_cache...`)
        const { data: cachedContent, error: fetchError } = await supabase
          .from('discovery_cache')
          .select('*')
          .limit(testMode ? 10 : country.content)

        if (fetchError) {
          throw new Error(`Failed to fetch cached content: ${fetchError.message}`)
        }

        // Map cached content to same format as TMDb content
        const tmdbContent = cachedContent.map((item: any) => ({
          id: item.tmdb_id,
          title: item.content_type === 'movie' ? item.title : null,
          name: item.content_type === 'tv' ? item.title : null,
          overview: item.overview,
          poster_path: item.poster_path,
          backdrop_path: item.backdrop_path,
          release_date: item.content_type === 'movie' ? item.release_date : null,
          first_air_date: item.content_type === 'tv' ? item.release_date : null,
          vote_average: item.vote_average,
          genre_ids: item.genres || [],
          mediaType: item.content_type,
        }))

        countryStats.contentFetched = tmdbContent.length
        console.log(`Using ${tmdbContent.length} existing items from discovery_cache`)

        // Fetch YouTube clips for each cached TMDb item
        const targetClips = testMode ? 5 : country.clips
        let clipsFound = 0

        for (const item of tmdbContent) {
          if (clipsFound >= targetClips) break

          const title = item.title || item.name
          console.log(`\nSearching clips for: ${title} (${item.mediaType})`)

          try {
            const clips = await searchYouTubeClips(
              title,
              item.mediaType,
              3 // Get 3 clips per movie/show
            )

            console.log(`  → Found ${clips.length} clips from YouTube`)

            for (const clip of clips) {
              if (clipsFound >= targetClips) break

              // Validate clip meets criteria
              const isValid = validateClip(clip)
              console.log(`  → Clip "${clip.title.substring(0, 40)}..." - Valid: ${isValid} (embeddable: ${clip.embeddable}, public: ${clip.publicAccess}, duration: ${clip.duration}s)`)

              if (!isValid) continue

              // Store clip with country/language metadata
              const stored = await storeClip(
                supabase,
                clip,
                item,
                country.code,
                country.language,
                country.code
              )

              if (stored) {
                clipsFound++
                countryStats.clipsStored++
                console.log(`  ✓ Stored clip: ${clipsFound}/${targetClips}`)
              }

              await delay(YOUTUBE_DELAY_MS)
            }

            countryStats.clipsFetched += clips.length
          } catch (error) {
            console.error(`Error fetching clips for "${title}":`, error)
            countryStats.errors++
          }
        }

        console.log(`✓ ${country.code}: ${countryStats.clipsStored} clips stored`)
      } catch (error) {
        console.error(`Error processing ${country.code}:`, error)
        countryStats.errors++
      }

      stats.push(countryStats)
    }

    // Generate summary report
    const totalContent = stats.reduce((sum, s) => sum + s.contentFetched, 0)
    const totalClips = stats.reduce((sum, s) => sum + s.clipsStored, 0)
    const totalErrors = stats.reduce((sum, s) => sum + s.errors, 0)

    return new Response(
      JSON.stringify({
        success: true,
        summary: {
          totalContent,
          totalClips,
          totalErrors,
          countriesProcessed: stats.length,
        },
        details: stats,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Fatal error in bulk ingestion:', error)
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
})

// Fetch TMDb content with specified distribution
async function fetchTMDbContent(
  apiKey: string,
  region: string,
  language: string,
  totalCount: number
): Promise<any[]> {
  const content: any[] = []

  const trendingMoviesCount = Math.floor(totalCount * CONTENT_MIX.trendingMovies)
  const popularMoviesCount = Math.floor(totalCount * CONTENT_MIX.popularMovies)
  const topRatedMoviesCount = Math.floor(totalCount * CONTENT_MIX.topRatedMovies)
  const trendingTVCount = totalCount - trendingMoviesCount - popularMoviesCount - topRatedMoviesCount

  // Fetch trending movies
  const trendingMovies = await fetchTMDbEndpoint(
    apiKey,
    'trending/movie/week',
    { language, region },
    trendingMoviesCount
  )
  content.push(...trendingMovies.map((m: any) => ({ ...m, mediaType: 'movie' })))

  await delay(TMDB_DELAY_MS)

  // Fetch popular movies
  const popularMovies = await fetchTMDbEndpoint(
    apiKey,
    'movie/popular',
    { language, region },
    popularMoviesCount
  )
  content.push(...popularMovies.map((m: any) => ({ ...m, mediaType: 'movie' })))

  await delay(TMDB_DELAY_MS)

  // Fetch top-rated movies
  const topRatedMovies = await fetchTMDbEndpoint(
    apiKey,
    'movie/top_rated',
    { language, region },
    topRatedMoviesCount
  )
  content.push(...topRatedMovies.map((m: any) => ({ ...m, mediaType: 'movie' })))

  await delay(TMDB_DELAY_MS)

  // Fetch trending TV shows
  const trendingTV = await fetchTMDbEndpoint(
    apiKey,
    'trending/tv/week',
    { language, region },
    trendingTVCount
  )
  content.push(...trendingTV.map((t: any) => ({ ...t, mediaType: 'tv' })))

  return content
}

// Fetch from TMDb API endpoint with pagination
async function fetchTMDbEndpoint(
  apiKey: string,
  endpoint: string,
  params: Record<string, string>,
  targetCount: number
): Promise<any[]> {
  const results: any[] = []
  let page = 1
  const maxPages = Math.ceil(targetCount / 20) // TMDb returns 20 items per page

  while (results.length < targetCount && page <= maxPages) {
    const url = new URL(`https://api.themoviedb.org/3/${endpoint}`)
    url.searchParams.set('api_key', apiKey)
    url.searchParams.set('page', page.toString())

    for (const [key, value] of Object.entries(params)) {
      url.searchParams.set(key, value)
    }

    console.log(`Fetching TMDb ${endpoint}, page ${page}...`)
    const response = await fetch(url.toString())

    if (!response.ok) {
      const errorText = await response.text()
      console.error(`TMDb API error: ${response.status} ${response.statusText}`)
      console.error(`Error details: ${errorText}`)
      console.error(`Request URL: ${url.toString().replace(apiKey, 'API_KEY_HIDDEN')}`)
      throw new Error(`TMDb API failed: ${response.status}`)
    }

    const data = await response.json()
    console.log(`Received ${data.results?.length || 0} items from TMDb`)

    if (!data.results || data.results.length === 0) {
      console.log('No more results from TMDb')
      break
    }

    results.push(...data.results)
    page++
    await delay(TMDB_DELAY_MS)
  }

  return results.slice(0, targetCount)
}

// Search YouTube for clips related to a movie/show
async function searchYouTubeClips(
  title: string,
  mediaType: string,
  maxResults: number
): Promise<YouTubeVideo[]> {
  const query = `${title} ${mediaType === 'movie' ? 'movie' : 'tv show'} clip trailer scene`
  const url = new URL(`${YOUTUBE_API_BASE}/search`)
  url.searchParams.set('key', YOUTUBE_API_KEY)
  url.searchParams.set('q', query)
  url.searchParams.set('part', 'snippet')
  url.searchParams.set('type', 'video')
  url.searchParams.set('maxResults', maxResults.toString())
  url.searchParams.set('videoEmbeddable', 'true')
  url.searchParams.set('videoSyndicated', 'true')

  console.log(`Searching YouTube for: "${title}"`)
  const response = await fetch(url.toString())

  if (!response.ok) {
    const errorText = await response.text()
    console.error(`YouTube API error: ${response.status}`)
    console.error(`Error details: ${errorText}`)
    return []
  }

  const data = await response.json()
  const videoIds = data.items?.map((item: any) => item.id.videoId).filter(Boolean) || []
  console.log(`Found ${videoIds.length} YouTube videos for "${title}"`)

  if (videoIds.length === 0) return []

  // Fetch video details to validate embeddability and duration
  return await fetchYouTubeVideoDetails(videoIds)
}

// Fetch detailed YouTube video information
async function fetchYouTubeVideoDetails(videoIds: string[]): Promise<YouTubeVideo[]> {
  const url = new URL(`${YOUTUBE_API_BASE}/videos`)
  url.searchParams.set('key', YOUTUBE_API_KEY)
  url.searchParams.set('id', videoIds.join(','))
  url.searchParams.set('part', 'snippet,contentDetails,status')

  console.log(`Fetching details for ${videoIds.length} YouTube videos...`)
  const response = await fetch(url.toString())

  if (!response.ok) {
    const errorText = await response.text()
    console.error(`YouTube videos API error: ${response.status}`)
    console.error(`Error details: ${errorText}`)
    return []
  }

  const data = await response.json()
  const videos: YouTubeVideo[] = []

  console.log(`Received ${data.items?.length || 0} video details from YouTube`)

  for (const item of data.items || []) {
    const duration = parseDuration(item.contentDetails.duration)
    const video: YouTubeVideo = {
      id: item.id,
      title: item.snippet.title,
      description: item.snippet.description,
      thumbnailUrl: item.snippet.thumbnails.high?.url || item.snippet.thumbnails.default.url,
      duration,
      embeddable: item.status.embeddable === true,
      publicAccess: item.status.privacyStatus === 'public',
    }
    videos.push(video)
  }

  return videos
}

// Parse ISO 8601 duration to seconds
function parseDuration(isoDuration: string): number {
  const match = isoDuration.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/)
  if (!match) return 0

  const hours = parseInt(match[1] || '0', 10)
  const minutes = parseInt(match[2] || '0', 10)
  const seconds = parseInt(match[3] || '0', 10)

  return hours * 3600 + minutes * 60 + seconds
}

// Validate clip meets ingestion criteria
function validateClip(clip: YouTubeVideo): boolean {
  // Must be embeddable and public
  if (!clip.embeddable || !clip.publicAccess) return false

  // Duration must be 30s - 10min
  if (clip.duration < 30 || clip.duration > 600) return false

  return true
}

// Store TMDb content in discovery_cache table
async function storeTMDbContent(supabase: any, item: any, region: string): Promise<void> {
  // Check if item already exists to avoid duplicates
  const { data: existing } = await supabase
    .from('discovery_cache')
    .select('id')
    .eq('tmdb_id', item.id)
    .eq('content_type', item.mediaType)
    .single()

  if (existing) {
    console.log(`TMDb content ${item.id} already cached, skipping`)
    return
  }

  const { error } = await supabase
    .from('discovery_cache')
    .insert({
      tmdb_id: item.id,
      content_type: item.mediaType,
      title: item.title || item.name,
      overview: item.overview,
      poster_path: item.poster_path,
      backdrop_path: item.backdrop_path,
      release_date: item.release_date || item.first_air_date,
      vote_average: item.vote_average,
      genres: item.genre_ids,
    })

  if (error) {
    console.error('Error storing TMDb content:', error)
  }
}

// Store YouTube clip with country/language metadata
async function storeClip(
  supabase: any,
  clip: YouTubeVideo,
  tmdbItem: any,
  countryCode: string,
  languageCode: string,
  sourceRegion: string
): Promise<boolean> {
  const clipId = `${clip.id}_${tmdbItem.id}_${tmdbItem.mediaType}`

  const clipData = {
    clip_id: clipId,
    video_id: clip.id,
    title: clip.title,
    description: clip.description,
    video_url: `https://www.youtube.com/watch?v=${clip.id}`,
    thumbnail_url: clip.thumbnailUrl,
    duration: clip.duration,
    movie_id: tmdbItem.mediaType === 'movie' ? tmdbItem.id : null,
    tv_show_id: tmdbItem.mediaType === 'tv' ? tmdbItem.id : null,
    media_type: tmdbItem.mediaType,
    likes: 0,
    comments: 0,
    // Country/Language metadata
    country_code: countryCode,
    language_code: languageCode,
    source_region: sourceRegion,
  }

  const { error } = await supabase
    .from('clips')
    .upsert(clipData, { onConflict: 'clip_id' })

  if (error) {
    console.error('Error storing clip:', error)
    return false
  }

  return true
}

// Utility delay function
function delay(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}
