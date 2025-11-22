import Foundation
import Supabase

/// Service responsible for pre-fetching and caching clips to Supabase
@MainActor
class ClipsPrefetchService: ObservableObject {
    static let shared = ClipsPrefetchService()
    
    @Published var isFetching = false
    @Published var lastFetchDate: Date?
    @Published var cachedClipsCount: Int = 0
    
    private let supabase = SupabaseService.shared
    private let tmdbService = TMDBService.shared
    private let youtubeAPIKey = "AIzaSyCh_tkrvBEGW6ALRvkAN-LYx1B3Cly1160"
    
    private let userDefaults = UserDefaults.standard
    private let lastFetchKey = "lastClipsPrefetchDate"
    private let cachedCountKey = "cachedClipsCount"
    
    private init() {
        loadLastFetchDate()
    }
    
    // MARK: - Main Pre-fetch Function
    
    /// Pre-fetch clips and store in Supabase
    /// - Parameter targetCount: How many clips to fetch (500-1000 recommended)
    /// - Returns: Number of clips successfully cached
    @discardableResult
    func prefetchClips(targetCount: Int = 800) async throws -> Int {
        guard !isFetching else {
            print("⚠️ [ClipsPrefetch] Already fetching, skipping...")
            return 0
        }
        
        print("🚀 [ClipsPrefetch] Starting pre-fetch of \(targetCount) clips...")
        isFetching = true
        
        var fetchedClips: [CachedClip] = []
        
        do {
            // 1. Get popular movies and TV shows from TMDB
            let movies = try await fetchPopularMovies(count: targetCount / 2)
            let tvShows = try await fetchPopularTVShows(count: targetCount / 2)
            
            print("📺 [ClipsPrefetch] Fetched \(movies.count) movies, \(tvShows.count) TV shows")
            
            // 2. Get clips for each movie/TV show
            for movie in movies {
                let clips = try await fetchClipsForMovie(movie)
                fetchedClips.append(contentsOf: clips)
                
                if fetchedClips.count >= targetCount {
                    break
                }
            }
            
            for tvShow in tvShows where fetchedClips.count < targetCount {
                let clips = try await fetchClipsForTVShow(tvShow)
                fetchedClips.append(contentsOf: clips)
                
                if fetchedClips.count >= targetCount {
                    break
                }
            }
            
            print("🎬 [ClipsPrefetch] Generated \(fetchedClips.count) clips from API")
            
            // 3. Store in Supabase
            let storedCount = try await storeClipsInSupabase(fetchedClips)
            
            // 4. Update metadata
            lastFetchDate = Date()
            cachedClipsCount = storedCount
            saveLastFetchDate()
            
            isFetching = false
            
            print("✅ [ClipsPrefetch] Successfully cached \(storedCount) clips!")
            return storedCount
            
        } catch {
            isFetching = false
            print("❌ [ClipsPrefetch] Error: \(error)")
            throw error
        }
    }
    
    // MARK: - Check if Fetch Needed
    
    /// Check if we need to fetch today
    func shouldFetchToday() -> Bool {
        guard let lastFetch = lastFetchDate else {
            return true // Never fetched before
        }
        
        // Check if last fetch was yesterday or earlier
        let calendar = Calendar.current
        return !calendar.isDateInToday(lastFetch)
    }
    
    // MARK: - Fetch Popular Content from TMDB
    
    private func fetchPopularMovies(count: Int) async throws -> [Movie] {
        var allMovies: [Movie] = []
        let pages = min(count / 20, 25) // TMDB returns ~20 per page, max 25 pages
        
        for page in 1...pages {
            let response = try await tmdbService.getPopularMovies(page: page)
            allMovies.append(contentsOf: response.results)
            
            // Small delay to respect rate limits
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        
        return Array(allMovies.prefix(count))
    }
    
    private func fetchPopularTVShows(count: Int) async throws -> [TVShow] {
        var allShows: [TVShow] = []
        let pages = min(count / 20, 25)
        
        for page in 1...pages {
            let response = try await tmdbService.getPopularTVShows(page: page)
            allShows.append(contentsOf: response.results)
            
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        return Array(allShows.prefix(count))
    }
    
    // MARK: - Fetch Clips for Media
    
    private func fetchClipsForMovie(_ movie: Movie) async throws -> [CachedClip] {
        var clips: [CachedClip] = []
        
        // Get videos from TMDB
        let videosResponse = try await tmdbService.getMovieVideos(id: movie.id)
        let youtubeVideos = videosResponse.results.filter { $0.site == "YouTube" }
        
        for video in youtubeVideos.prefix(3) { // Max 3 clips per movie
            let cachedClip = CachedClip(
                clipId: "movie_\(movie.id)_\(video.key)",
                videoId: video.key,
                title: movie.title,
                description: video.name,
                videoUrl: "https://www.youtube.com/watch?v=\(video.key)",
                thumbnailUrl: "https://img.youtube.com/vi/\(video.key)/maxresdefault.jpg",
                movieId: movie.id,
                tvShowId: nil,
                mediaType: "movie",
                genres: movie.genreIds?.compactMap { genreIdToName($0) } ?? [],
                tmdbRating: movie.voteAverage,
                youtubeViews: 0, // We'll skip fetching YouTube stats for speed
                qualityScore: 0.5 // Default, will calculate
            )
            
            clips.append(cachedClip)
        }
        
        return clips
    }
    
    private func fetchClipsForTVShow(_ tvShow: TVShow) async throws -> [CachedClip] {
        var clips: [CachedClip] = []
        
        let videosResponse = try await tmdbService.getTVShowVideos(id: tvShow.id)
        let youtubeVideos = videosResponse.results.filter { $0.site == "YouTube" }
        
        for video in youtubeVideos.prefix(3) {
            let cachedClip = CachedClip(
                clipId: "tv_\(tvShow.id)_\(video.key)",
                videoId: video.key,
                title: tvShow.name,
                description: video.name,
                videoUrl: "https://www.youtube.com/watch?v=\(video.key)",
                thumbnailUrl: "https://img.youtube.com/vi/\(video.key)/maxresdefault.jpg",
                movieId: nil,
                tvShowId: tvShow.id,
                mediaType: "tv",
                genres: tvShow.genreIds?.compactMap { genreIdToName($0) } ?? [],
                tmdbRating: tvShow.voteAverage,
                youtubeViews: 0,
                qualityScore: 0.5
            )
            
            clips.append(cachedClip)
        }
        
        return clips
    }
    
    // MARK: - Store in Supabase
    
    private func storeClipsInSupabase(_ clips: [CachedClip]) async throws -> Int {
        guard let client = supabase.client else {
            throw ClipsPrefetchError.supabaseNotConfigured
        }
        
        var storedCount = 0
        
        // Insert in batches of 50 to avoid timeout (smaller batches for stability)
        let batchSize = 50
        for batchIndex in stride(from: 0, to: clips.count, by: batchSize) {
            let endIndex = min(batchIndex + batchSize, clips.count)
            let batch = Array(clips[batchIndex..<endIndex])
            
            do {
                // Try upsert first (Codable structs are used directly)
                let _: [CachedClip] = try await client
                    .from("clips")
                    .upsert(batch)
                    .execute()
                    .value
                
                storedCount += batch.count
                print("💾 [ClipsPrefetch] Stored batch: \(storedCount)/\(clips.count)")
                
            } catch {
                // If upsert fails due to RLS, try insert without conflict check
                print("⚠️ [ClipsPrefetch] Upsert failed, trying insert: \(error)")
                
                do {
                    let _: [CachedClip] = try await client
                        .from("clips")
                        .insert(batch)
                        .execute()
                        .value
                    
                    storedCount += batch.count
                    print("💾 [ClipsPrefetch] Inserted batch: \(storedCount)/\(clips.count)")
                } catch {
                    print("❌ [ClipsPrefetch] Batch insert also failed: \(error)")
                    // Continue with next batch
                }
            }
            
            // Small delay between batches to avoid rate limiting
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        }
        
        return storedCount
    }
    
    // MARK: - Utilities
    
    private func genreIdToName(_ id: Int) -> String? {
        let genreMap: [Int: String] = [
            28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
            80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
            14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
            9648: "Mystery", 10749: "Romance", 878: "Sci-Fi", 10770: "TV Movie",
            53: "Thriller", 10752: "War", 37: "Western"
        ]
        return genreMap[id]
    }
    
    private func loadLastFetchDate() {
        if let timestamp = userDefaults.object(forKey: lastFetchKey) as? Date {
            lastFetchDate = timestamp
        }
        cachedClipsCount = userDefaults.integer(forKey: cachedCountKey)
    }
    
    private func saveLastFetchDate() {
        userDefaults.set(lastFetchDate, forKey: lastFetchKey)
        userDefaults.set(cachedClipsCount, forKey: cachedCountKey)
    }
}

// MARK: - Models

struct CachedClip: Codable {
    let clipId: String
    let videoId: String
    let title: String
    let description: String
    let videoUrl: String
    let thumbnailUrl: String
    let movieId: Int?
    let tvShowId: Int?
    let mediaType: String
    let genres: [String]
    let tmdbRating: Double?
    let youtubeViews: Int
    let qualityScore: Double
    
    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id"
        case videoId = "video_id"
        case title
        case description
        case videoUrl = "video_url"
        case thumbnailUrl = "thumbnail_url"
        case movieId = "movie_id"
        case tvShowId = "tv_show_id"
        case mediaType = "media_type"
        case genres
        case tmdbRating = "tmdb_rating"
        case youtubeViews = "youtube_views"
        case qualityScore = "quality_score"
    }
}

enum ClipsPrefetchError: Error {
    case supabaseNotConfigured
    case fetchFailed
}
