// Supabase Edge Function - Weekly Content Curator
// This function runs weekly via cron job to add 200 clips and 100 movies/shows
// Schedule: Every Sunday at 00:00 UTC

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'

// YouTube API configuration
const YOUTUBE_API_KEY = Deno.env.get('YOUTUBE_API_KEY')!
const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY')!
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
// Prefer the new secret key (sb_secret_..., auto-injected as SUPABASE_SECRET_KEYS json),
// falling back to the legacy service_role during the migration window.
const SUPABASE_SERVICE_ROLE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  try {
    console.log('🎬 [Curator] Starting weekly content curation...')

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

    // Step 1: Curate and validate 200 new clips
    const newClips = await curateNewClips(supabase, 200)
    console.log(`✅ [Curator] Curated ${newClips.length} validated clips`)

    // Step 2: Curate 100 new movies/shows
    const newMovies = await curateNewMovies(supabase, 100)
    console.log(`✅ [Curator] Curated ${newMovies.length} movies/shows`)

    // Step 3: Store in database
    await storeClipsInDatabase(supabase, newClips)
    await storeMoviesInDatabase(supabase, newMovies)

    return new Response(
      JSON.stringify({
        success: true,
        clipsAdded: newClips.length,
        moviesAdded: newMovies.length,
        timestamp: new Date().toISOString()
      }),
      { headers: { "Content-Type": "application/json" } }
    )

  } catch (error) {
    console.error('❌ [Curator] Error:', error)
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    )
  }
})

// MARK: - Clip Curation

async function curateNewClips(supabase: any, targetCount: number) {
  const curatedClips: any[] = []
  let attemptedCount = 0
  const maxAttempts = targetCount * 3

  console.log('🎬 [Curator] Fetching trending movies for clip extraction...')

  // Get trending movies and TV shows from TMDB
  const trendingMovies = await fetchTrendingMovies()
  const trendingTV = await fetchTrendingTV()
  const allMedia = [...trendingMovies, ...trendingTV]

  for (const movie of allMedia) {
    if (curatedClips.length >= targetCount || attemptedCount >= maxAttempts) break

    // Search for clips/trailers for this movie
    const potentialClips = await searchYouTubeClips(movie)
    attemptedCount += potentialClips.length

    for (const clipCandidate of potentialClips) {
      if (curatedClips.length >= targetCount) break

      // Validate with YouTube API
      const validated = await validateYouTubeVideo(clipCandidate.videoId)

      if (validated) {
        // Check if this clip already exists
        const { data: existing } = await supabase
          .from('clips')
          .select('id')
          .eq('video_id', clipCandidate.videoId)
          .single()

        if (!existing) {
          curatedClips.push({
            videoId: clipCandidate.videoId,
            title: clipCandidate.title,
            description: clipCandidate.description,
            movieId: movie.id,
            tvShowId: null,
            mediaType: 'movie',
            thumbnailUrl: validated.thumbnailUrl,
            duration: validated.duration,
            genres: movie.genre_ids || [],
            mood: inferMood(movie.genre_ids || [])
          })
          console.log(`✅ [Curator] Added clip: ${clipCandidate.title}`)
        }
      } else {
        console.log(`❌ [Curator] Rejected invalid clip: ${clipCandidate.videoId}`)
      }

      // Rate limiting
      await new Promise(resolve => setTimeout(resolve, 100))
    }
  }

  return curatedClips
}

async function searchYouTubeClips(movie: any) {
  const searchQuery = encodeURIComponent(`${movie.title} movie clip scene`)
  const url = `https://www.googleapis.com/youtube/v3/search?part=snippet&q=${searchQuery}&type=video&videoDuration=short&maxResults=5&key=${YOUTUBE_API_KEY}`

  const response = await fetch(url)
  const data = await response.json()

  if (!data.items) return []

  return data.items.map((item: any) => ({
    videoId: item.id.videoId,
    title: item.snippet.title,
    description: item.snippet.description
  }))
}

async function validateYouTubeVideo(videoId: string) {
  const url = `https://www.googleapis.com/youtube/v3/videos?id=${videoId}&part=snippet,contentDetails,status&key=${YOUTUBE_API_KEY}`

  const response = await fetch(url)
  const data = await response.json()

  if (!data.items || data.items.length === 0) {
    return null // Video not found
  }

  const video = data.items[0]

  // Check if embeddable (not age-restricted)
  if (!video.status.embeddable) {
    console.log(`⚠️ Video ${videoId} is not embeddable`)
    return null
  }

  // Check if has video track (not audio-only)
  if (video.contentDetails.definition === 'none') {
    console.log(`⚠️ Video ${videoId} is audio-only`)
    return null
  }

  // Check age restriction
  if (video.contentDetails.contentRating?.ytRating === 'ytAgeRestricted') {
    console.log(`⚠️ Video ${videoId} is age-restricted`)
    return null
  }

  // Parse duration
  const duration = parseDuration(video.contentDetails.duration)

  // Check duration (30s - 10min)
  if (duration < 30 || duration > 600) {
    console.log(`⚠️ Video ${videoId} duration out of range: ${duration}s`)
    return null
  }

  return {
    thumbnailUrl: video.snippet.thumbnails.high?.url || video.snippet.thumbnails.medium?.url,
    duration
  }
}

function parseDuration(duration: string): number {
  let totalSeconds = 0
  let currentNumber = ''

  for (const char of duration) {
    if (char >= '0' && char <= '9') {
      currentNumber += char
    } else if (char === 'H') {
      totalSeconds += parseInt(currentNumber) * 3600
      currentNumber = ''
    } else if (char === 'M') {
      totalSeconds += parseInt(currentNumber) * 60
      currentNumber = ''
    } else if (char === 'S') {
      totalSeconds += parseInt(currentNumber)
      currentNumber = ''
    }
  }

  return totalSeconds
}

// MARK: - Movie/Show Curation

async function curateNewMovies(supabase: any, targetCount: number) {
  console.log('🎬 [Curator] Fetching new movies/shows from TMDB...')

  const moviesNeeded = Math.floor(targetCount / 2)
  const tvNeeded = targetCount - moviesNeeded

  const trendingMovies = await fetchTrendingMovies()
  const popularMovies = await fetchPopularMovies()
  const trendingTV = await fetchTrendingTV()
  const popularTV = await fetchPopularTV()

  // Deduplicate and limit
  const allMovies = [...new Set([...trendingMovies, ...popularMovies].map(m => m.id))]
    .map(id => [...trendingMovies, ...popularMovies].find(m => m.id === id))
    .slice(0, moviesNeeded)

  const allTV = [...new Set([...trendingTV, ...popularTV].map(t => t.id))]
    .map(id => [...trendingTV, ...popularTV].find(t => t.id === id))
    .slice(0, tvNeeded)

  const curatedMovies = []

  // Filter out existing content
  for (const movie of allMovies) {
    const { data: existing } = await supabase
      .from('discovery_content')
      .select('id')
      .eq('tmdb_id', movie.id)
      .eq('media_type', 'movie')
      .single()

    if (!existing) {
      curatedMovies.push({
        tmdbId: movie.id,
        title: movie.title,
        overview: movie.overview,
        posterPath: movie.poster_path,
        backdropPath: movie.backdrop_path,
        releaseDate: movie.release_date,
        voteAverage: movie.vote_average,
        genreIds: movie.genre_ids,
        mediaType: 'movie'
      })
    }
  }

  for (const show of allTV) {
    const { data: existing } = await supabase
      .from('discovery_content')
      .select('id')
      .eq('tmdb_id', show.id)
      .eq('media_type', 'tv')
      .single()

    if (!existing) {
      curatedMovies.push({
        tmdbId: show.id,
        title: show.name,
        overview: show.overview,
        posterPath: show.poster_path,
        backdropPath: show.backdrop_path,
        releaseDate: show.first_air_date,
        voteAverage: show.vote_average,
        genreIds: show.genre_ids,
        mediaType: 'tv'
      })
    }
  }

  return curatedMovies
}

// MARK: - TMDB API Calls

async function fetchTrendingMovies() {
  const url = `https://api.themoviedb.org/3/trending/movie/week?api_key=${TMDB_API_KEY}`
  const response = await fetch(url)
  const data = await response.json()
  return data.results || []
}

async function fetchPopularMovies() {
  const url = `https://api.themoviedb.org/3/movie/popular?api_key=${TMDB_API_KEY}`
  const response = await fetch(url)
  const data = await response.json()
  return data.results || []
}

async function fetchTrendingTV() {
  const url = `https://api.themoviedb.org/3/trending/tv/week?api_key=${TMDB_API_KEY}`
  const response = await fetch(url)
  const data = await response.json()
  return data.results || []
}

async function fetchPopularTV() {
  const url = `https://api.themoviedb.org/3/tv/popular?api_key=${TMDB_API_KEY}`
  const response = await fetch(url)
  const data = await response.json()
  return data.results || []
}

// MARK: - Database Storage

async function storeClipsInDatabase(supabase: any, clips: any[]) {
  console.log(`💾 [Curator] Storing ${clips.length} clips in database...`)

  for (const clip of clips) {
    const { error } = await supabase.from('clips').insert({
      id: crypto.randomUUID(),
      clip_id: clip.videoId,
      video_id: clip.videoId,
      title: clip.title,
      description: clip.description,
      video_url: `https://www.youtube.com/watch?v=${clip.videoId}`,
      thumbnail_url: clip.thumbnailUrl,
      movie_id: clip.movieId,
      tv_show_id: clip.tvShowId,
      media_type: clip.mediaType,
      genres: clip.genres,
      mood: clip.mood,
      duration: clip.duration,
      is_active: true,
      is_premium: false,
      likes: 0,
      comments: 0,
      views: 0,
      created_at: new Date().toISOString()
    })

    if (error) {
      console.error(`❌ Failed to store clip ${clip.videoId}:`, error)
    }
  }

  console.log('✅ [Curator] Stored all clips')
}

async function storeMoviesInDatabase(supabase: any, movies: any[]) {
  console.log(`💾 [Curator] Storing ${movies.length} movies/shows in database...`)

  for (const movie of movies) {
    const { error } = await supabase.from('discovery_content').insert({
      id: crypto.randomUUID(),
      tmdb_id: movie.tmdbId,
      title: movie.title,
      overview: movie.overview,
      poster_path: movie.posterPath,
      backdrop_path: movie.backdropPath,
      release_date: movie.releaseDate,
      vote_average: movie.voteAverage,
      genre_ids: movie.genreIds,
      media_type: movie.mediaType,
      created_at: new Date().toISOString()
    })

    if (error) {
      console.error(`❌ Failed to store movie ${movie.tmdbId}:`, error)
    }
  }

  console.log('✅ [Curator] Stored all movies/shows')
}

// MARK: - Helpers

function inferMood(genreIds: number[]): string {
  if (genreIds.includes(28)) return 'action'
  if (genreIds.includes(35)) return 'comedy'
  if (genreIds.includes(18)) return 'drama'
  if (genreIds.includes(27)) return 'horror'
  if (genreIds.includes(10749)) return 'romantic'
  if (genreIds.includes(878)) return 'sci-fi'
  if (genreIds.includes(53)) return 'thriller'
  return 'entertaining'
}
