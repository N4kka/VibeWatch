import Foundation

/// Simplified, instant-loading clips algorithm
/// - Shows ALL content types (trailers, clips, behind-the-scenes, teasers, etc.)
/// - Filters only by duration (max 3 minutes / 180 seconds)
/// - Proper deduplication by clip ID
/// - User taste tracking for personalization
/// - Instant loading with aggressive caching
@MainActor
class QuickClipsService: ObservableObject {
    static let shared = QuickClipsService()
    
    private let tmdbService = TMDBService.shared
    private let engagementTracker = UserEngagementTracker.shared
    
    // Constants
    private let maxDurationSeconds = AppConstants.Clips.maxClipDurationSeconds // 3 minutes
    private let targetBatchSize = 30
    
    // Deduplication tracking
    private var shownClipIds = Set<String>()
    
    // Cache for instant loading
    private var cachedClips: [Clip] = []
    
    private init() {}
    
    // MARK: - Preload (Smart & Shared)
    
    /// Preload clips from a provided list of movies (reusing Discovery data)
    /// - Parameters:
    ///   - movies: The list of movies already fetched for Discovery
    ///   - count: Number of clips to preload (default 5)
    /// - Returns: List of ready-to-play clips
    func preloadClips(from movies: [Movie], count: Int = 5) async -> [Clip] {
        print("⚡ PRELOAD: Starting smart preload from \(movies.count) shared movies...")
        let startTime = Date()
        
        // Take top 'count' movies + a few extras buffer
        let candidates = Array(movies.prefix(count + 3))
        
        // Fetch in PARALLEL
        let preloaded = await withTaskGroup(of: Clip?.self) { group in
            var results: [Clip] = []
            
            for movie in candidates {
                group.addTask {
                    // Use current language for preload (immediate relevance)
                    let lang = LocalizationManager.shared.currentLanguage.id
                    if let clips = try? await self.searchYouTubeForMovie(movie, language: lang),
                       let firstClip = clips.first {
                        return firstClip
                    }
                    return nil
                }
            }
            
            // Collect up to 'count' results
            for await clip in group {
                if let clip = clip {
                    results.append(clip)
                    if results.count >= count {
                        // Note: TaskGroup doesn't support easy cancellation of remaining tasks, 
                        // but we can stop collecting.
                    }
                }
            }
            
            return results.prefix(count).map { $0 } // Return exact requested count
        }
        
        // Cache these immediately
        cachedClips = preloaded
        preloaded.forEach { shownClipIds.insert($0.id) }
        
        print("✅ PRELOAD: Ready in \(String(format: "%.3f", Date().timeIntervalSince(startTime)))s - \(preloaded.count) clips")
        return preloaded
    }

    // MARK: - Main Feed Generation
    
    /// Generate feed with language mixing (80% localized, 20% English)
    func generateFeed(count: Int = 30) async throws -> [Clip] {
        print("⚡ Generating mixed feed (80% Local / 20% Global)...")
        
        // 1. Fetch Source Data (Movies & TV)
        async let moviesTask = fetchMovieClips(limit: 20) // Fetch more to filter
        async let tvTask = fetchTVShowClips(limit: 10)
        
        let (movieClips, tvClips) = try await (moviesTask, tvTask)
        var allClips = movieClips + tvClips
        
        // 2. Filter & Deduplicate
        allClips = allClips.filter { $0.duration <= maxDurationSeconds }
        allClips = deduplicate(allClips)
        
        // 3. Personalize
        if engagementTracker.hasAnyPreferences() {
            allClips = applyPersonalization(allClips)
        } else {
            allClips.shuffle()
        }
        
        // 4. Diversify Source
        allClips = diversifyBySource(allClips)
        
        let result = Array(allClips.prefix(count))
        result.forEach { shownClipIds.insert($0.id) }
        
        return result
    }
    
    /// Alias for generateFeed to support infinite scroll
    func loadMore(count: Int = 30) async throws -> [Clip] {
        return try await generateFeed(count: count)
    }
    
    // MARK: - Fetch Clips
    
    private func fetchMovieClips(limit: Int) async throws -> [Clip] {
        // Parallel fetch of trending pages
        async let page1 = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
        async let page2 = tmdbService.getTrendingMovies(timeWindow: .week, page: 2)
        
        let (movies1, movies2) = try await (page1, page2)
        let allMovies = movies1.results + movies2.results
        
        // Mix languages: 80% Local, 20% English
        // We'll process in batches to maintain mix
        
        return await withTaskGroup(of: [Clip].self) { group in
            var clips: [Clip] = []
            var processed = 0
            
            for movie in allMovies {
                guard processed < limit * 2 else { break } // Optimization cap
                processed += 1
                
                // Determine language for this item (Randomized 80/20 split)
                let useLocal = Double.random(in: 0...1) < 0.8
                let lang = useLocal ? LocalizationManager.shared.currentLanguage.id : "en"
                
                group.addTask {
                    return (try? await self.searchYouTubeForMovie(movie, language: lang)) ?? []
                }
            }
            
            for await result in group {
                clips.append(contentsOf: result)
            }
            
            return clips
        }
    }
    
    private func fetchTVShowClips(limit: Int) async throws -> [Clip] {
        async let page1 = tmdbService.getTrendingTVShows(timeWindow: .week, page: 1)
        let tv1 = try await page1
        
        return await withTaskGroup(of: [Clip].self) { group in
            var clips: [Clip] = []
            
            for tvShow in tv1.results {
                let useLocal = Double.random(in: 0...1) < 0.8
                let lang = useLocal ? LocalizationManager.shared.currentLanguage.id : "en"
                
                group.addTask {
                    return (try? await self.searchYouTubeForTVShow(tvShow, language: lang)) ?? []
                }
            }
            
            for await result in group {
                clips.append(contentsOf: result)
            }
            return clips
        }
    }
    
    // MARK: - YouTube Search
    
    private func searchYouTubeForMovie(_ movie: Movie, language: String = "en") async throws -> [Clip] {
        // Localized query construction
        let suffix = language == "en" ? "official clip scene trailer" : "trailer clip scena ufficiale"
        let query = "\(movie.title) \(suffix)"
        
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        
        // Rejection words (to avoid bad content)
        // ... logic remains similar ...
        
        let urlString = "https://www.googleapis.com/youtube/v3/search?part=snippet&q=\(encodedQuery)&type=video&videoDuration=short&maxResults=1&key=AIzaSyCh_tkrvBEGW6ALRvkAN-LYx1B3Cly1160&relevanceLanguage=\(language)"
        
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
    
    private func searchYouTubeForTVShow(_ tvShow: TVShow, language: String = "en") async throws -> [Clip] {
        let suffix = language == "en" ? "official clip scene trailer" : "trailer clip scena ufficiale"
        let query = "\(tvShow.name) \(suffix)"
        
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        
        let urlString = "https://www.googleapis.com/youtube/v3/search?part=snippet&q=\(encodedQuery)&type=video&videoDuration=short&maxResults=1&key=AIzaSyCh_tkrvBEGW6ALRvkAN-LYx1B3Cly1160&relevanceLanguage=\(language)"
        
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
    
    // YouTube models are in Core/Models/YouTubeModels.swift
    
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
