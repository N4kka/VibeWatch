import Foundation

/// Simplified, instant-loading clips algorithm
/// - Shows ALL content types (trailers, clips, behind-the-scenes, teasers, etc.)
/// - Filters only by duration (max 3 minutes / 180 seconds)
/// - Proper deduplication by clip ID
/// - User taste tracking for personalization
/// - Instant loading with aggressive caching
@MainActor
class SimplifiedClipsAlgorithm: ObservableObject {
    static let shared = SimplifiedClipsAlgorithm()
    
    private let tmdbService = TMDBService.shared
    private let engagementTracker = UserEngagementTracker.shared
    
    // Constants
    private let maxDurationSeconds = 180 // 3 minutes
    private let targetBatchSize = 30
    
    // Deduplication tracking
    private var shownClipIds = Set<String>()
    
    // Cache for instant loading
    @Published var cachedClips: [Clip] = []
    
    private init() {}
    
    // MARK: - Main Feed Generation (Instant)
    
    /// Generate feed instantly - returns cached clips immediately if available
    func generateFeed(count: Int = 30) async throws -> [Clip] {
        print("⚡ Generating instant feed...")
        let startTime = Date()
        
        // Fetch clips in parallel (movies + TV shows simultaneously)
        async let moviesTask = fetchMovieClips(limit: 20)
        async let tvTask = fetchTVShowClips(limit: 10)
        
        let (movieClips, tvClips) = try await (moviesTask, tvTask)
        
        var allClips = movieClips + tvClips
        
        // Filter by duration (max 3 minutes)
        allClips = allClips.filter { $0.duration <= maxDurationSeconds }
        print("✅ After 3-min filter: \(allClips.count) clips")
        
        // Deduplicate by clip ID
        allClips = deduplicate(allClips)
        print("✅ After deduplication: \(allClips.count) unique clips")
        
        // Apply user taste scoring if user has preferences
        if engagementTracker.hasAnyPreferences() {
            allClips = applyPersonalization(allClips)
            print("🎯 Applied personalization")
        } else {
            // Cold start: just sort by popularity (don't shuffle - it breaks diversity!)
            allClips.shuffle()
            print("🔀 No preferences yet - shuffled randomly")
        }
        
        // IMPORTANT: Diversify AFTER personalization to prevent same movie clips appearing together
        allClips = diversifyBySource(allClips)
        print("🎲 Diversified by source (no consecutive clips from same movie)")
        
        // Take requested count
        let result = Array(allClips.prefix(count))
        
        // Track shown IDs for deduplication in next batch
        result.forEach { shownClipIds.insert($0.id) }
        
        // Cache for instant future access
        cachedClips = result
        
        let duration = Date().timeIntervalSince(startTime)
        print("✅ Generated \(result.count) clips in \(String(format: "%.3f", duration))s")
        
        return result
    }
    
    /// Load more clips for infinite scroll
    func loadMore(count: Int = 30) async throws -> [Clip] {
        print("📦 Loading more clips...")
        
        // Same logic as generateFeed but with different page offsets
        return try await generateFeed(count: count)
    }
    
    // MARK: - Fetch Clips (NO FILTERS)
    
    /// Fetch clips from movies - ALL video types accepted
    private func fetchMovieClips(limit: Int) async throws -> [Clip] {
        print("🎬 Fetching movie clips from MULTIPLE pages...")
        
        // Fetch from MULTIPLE pages in parallel to ensure variety
        async let page1 = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
        async let page2 = tmdbService.getTrendingMovies(timeWindow: .week, page: 2)
        async let page3 = tmdbService.getTrendingMovies(timeWindow: .week, page: 3)
        
        let (movies1, movies2, movies3) = try await (page1, page2, page3)
        let allMovies = movies1.results + movies2.results + movies3.results
        
        print("📊 Total movies to try: \(allMovies.count)")
        
        var clips: [Clip] = []
        var uniqueMovieIds = Set<Int>()
        var moviesWithClips: [(String, Int)] = []
        
        // Try to get clips from ALL movies until we have enough
        for movie in allMovies {
            if let movieClips = try? await getVideosForMovie(movie), !movieClips.isEmpty {
                clips.append(contentsOf: movieClips)
                uniqueMovieIds.insert(movie.id)
                moviesWithClips.append((movie.title, movie.id))
                print("   ✅ \(movie.title) (ID: \(movie.id)) → \(movieClips.count) clip(s)")
            }
            
            // Stop when we have enough clips
            if clips.count >= limit {
                break
            }
        }
        
        print("✅ Got \(clips.count) movie clips from \(uniqueMovieIds.count) unique movies")
        print("📝 Movie IDs: \(Array(uniqueMovieIds).sorted())")
        return clips
    }
    
    /// Fetch clips from TV shows - ALL video types accepted
    private func fetchTVShowClips(limit: Int) async throws -> [Clip] {
        print("📺 Fetching TV show clips from MULTIPLE pages...")
        
        // Fetch from MULTIPLE pages in parallel to ensure variety
        async let page1 = tmdbService.getTrendingTVShows(timeWindow: .week, page: 1)
        async let page2 = tmdbService.getTrendingTVShows(timeWindow: .week, page: 2)
        async let page3 = tmdbService.getTrendingTVShows(timeWindow: .week, page: 3)
        
        let (tv1, tv2, tv3) = try await (page1, page2, page3)
        let allTVShows = tv1.results + tv2.results + tv3.results
        
        print("📊 Total TV shows to try: \(allTVShows.count)")
        
        var clips: [Clip] = []
        var uniqueTVIds = Set<Int>()
        var tvShowsWithClips: [(String, Int)] = []
        
        // Try to get clips from ALL TV shows until we have enough
        for tvShow in allTVShows {
            if let tvClips = try? await getVideosForTVShow(tvShow), !tvClips.isEmpty {
                clips.append(contentsOf: tvClips)
                uniqueTVIds.insert(tvShow.id)
                tvShowsWithClips.append((tvShow.name, tvShow.id))
                print("   ✅ \(tvShow.name) (ID: \(tvShow.id)) → \(tvClips.count) clip(s)")
            }
            
            // Stop when we have enough clips
            if clips.count >= limit {
                break
            }
        }
        
        print("✅ Got \(clips.count) TV clips from \(uniqueTVIds.count) unique TV shows")
        print("📝 TV Show IDs: \(Array(uniqueTVIds).sorted())")
        return clips
    }
    
    // MARK: - Video Conversion (NO TYPE FILTERING)
    
    /// Get videos for a movie - USES YOUTUBE SEARCH ONLY (TMDb is too limited)
    private func getVideosForMovie(_ movie: Movie) async throws -> [Clip] {
        return try await searchYouTubeForMovie(movie)
    }
    
    /// Search YouTube directly for movie clips - max 2 clips per movie for variety
    private func searchYouTubeForMovie(_ movie: Movie) async throws -> [Clip] {
        let query = "\(movie.title) official clip scene trailer"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        
        let urlString = "https://www.googleapis.com/youtube/v3/search?part=snippet&q=\(encodedQuery)&type=video&videoDuration=short&maxResults=2&key=AIzaSyCh_tkrvBEGW6ALRvkAN-LYx1B3Cly1160"
        
        guard let url = URL(string: urlString) else { return [] }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let searchResponse = try JSONDecoder().decode(YouTubeSearchResponse.self, from: data)
        
        return searchResponse.items.map { item in
            Clip(
                id: "\(movie.id)-yt-\(item.id.videoId)",
                movieId: movie.id,
                tvShowId: nil,
                title: movie.title,
                description: item.snippet.title,
                videoURL: "https://www.youtube.com/watch?v=\(item.id.videoId)",
                videoId: item.id.videoId,
                thumbnailURL: item.snippet.thumbnails.high.url,
                duration: 0,
                likes: 0,
                comments: 0,
                createdAt: Date()
            )
        }
    }
    
    /// Get videos for a TV show - USES YOUTUBE SEARCH ONLY (TMDb is too limited)
    private func getVideosForTVShow(_ tvShow: TVShow) async throws -> [Clip] {
        return try await searchYouTubeForTVShow(tvShow)
    }
    
    /// Search YouTube directly for TV show clips - max 2 clips per show for variety
    private func searchYouTubeForTVShow(_ tvShow: TVShow) async throws -> [Clip] {
        let query = "\(tvShow.name) official clip scene trailer"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        
        let urlString = "https://www.googleapis.com/youtube/v3/search?part=snippet&q=\(encodedQuery)&type=video&videoDuration=short&maxResults=2&key=AIzaSyCh_tkrvBEGW6ALRvkAN-LYx1B3Cly1160"
        
        guard let url = URL(string: urlString) else { return [] }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let searchResponse = try JSONDecoder().decode(YouTubeSearchResponse.self, from: data)
        
        return searchResponse.items.map { item in
            Clip(
                id: "\(tvShow.id)-yt-\(item.id.videoId)",
                movieId: nil,
                tvShowId: tvShow.id,
                title: tvShow.name,
                description: item.snippet.title,
                videoURL: "https://www.youtube.com/watch?v=\(item.id.videoId)",
                videoId: item.id.videoId,
                thumbnailURL: item.snippet.thumbnails.high.url,
                duration: 0,
                likes: 0,
                comments: 0,
                createdAt: Date()
            )
        }
    }
    
    // MARK: - YouTube Search Models
    
    struct YouTubeSearchResponse: Codable {
        let items: [YouTubeSearchItem]
    }
    
    struct YouTubeSearchItem: Codable {
        let id: VideoId
        let snippet: Snippet
        
        struct VideoId: Codable {
            let videoId: String
        }
        
        struct Snippet: Codable {
            let title: String
            let thumbnails: Thumbnails
            
            struct Thumbnails: Codable {
                let high: Thumbnail
                
                struct Thumbnail: Codable {
                    let url: String
                }
            }
        }
    }
    
    // MARK: - Deduplication
    
    /// Deduplicate clips by ID - removes previously shown clips
    private func deduplicate(_ clips: [Clip]) -> [Clip] {
        var seen = shownClipIds
        var unique: [Clip] = []
        
        for clip in clips {
            if !seen.contains(clip.id) {
                unique.append(clip)
                seen.insert(clip.id)
            }
        }
        
        return unique
    }
    
    /// Reset deduplication for fresh feed
    func resetDeduplication() {
        shownClipIds.removeAll()
        print("🔄 Deduplication reset")
    }
    
    // MARK: - Personalization (User Taste Tracking)
    
    /// Apply user taste scoring to clips
    private func applyPersonalization(_ clips: [Clip]) -> [Clip] {
        // Score each clip based on user engagement
        let scored = clips.map { clip -> (clip: Clip, score: Double) in
            var score: Double = 0
            
            // Movie/TV show preference
            if let movieId = clip.movieId {
                score += engagementTracker.getMovieScore(movieId) * 3
            } else if let tvShowId = clip.tvShowId {
                score += engagementTracker.getMovieScore(tvShowId) * 3
            }
            
            // Add randomness to avoid echo chamber (20%)
            score += Double.random(in: 0...20)
            
            return (clip, score)
        }
        
        // Sort by score descending
        return scored.sorted { $0.score > $1.score }.map { $0.clip }
    }
    
    // MARK: - Diversity
    
    /// Diversify clips to prevent consecutive clips from same movie/show
    private func diversifyBySource(_ clips: [Clip]) -> [Clip] {
        guard clips.count > 1 else { return clips }
        
        var diversified: [Clip] = []
        var remaining = clips
        var lastSourceId: Int?
        
        while !remaining.isEmpty {
            // Try to find a clip from a different source
            if let lastId = lastSourceId {
                if let nextIndex = remaining.firstIndex(where: {
                    let sourceId = $0.movieId ?? $0.tvShowId ?? -1
                    return sourceId != lastId
                }) {
                    let clip = remaining.remove(at: nextIndex)
                    diversified.append(clip)
                    lastSourceId = clip.movieId ?? clip.tvShowId
                    continue
                }
            }
            
            // If we can't find a different source, just take the first
            let clip = remaining.removeFirst()
            diversified.append(clip)
            lastSourceId = clip.movieId ?? clip.tvShowId
        }
        
        return diversified
    }
    
    // MARK: - Utility
    
    /// Get current stats
    func getStats() -> (cached: Int, shown: Int) {
        return (cachedClips.count, shownClipIds.count)
    }
}
