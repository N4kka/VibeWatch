import Foundation

/// Centralized data coordinator for optimal app loading strategy
/// 
/// Loading Strategy:
/// - Splash Screen: Task 1 (Discovery data) + Task 2 (5 initial clips) run in parallel
/// - Discovery appears: Uses cached data instantly (no waiting)
/// - Background: Starts fetching 20 more clips
/// - Clips scrolling: Smart pagination with minimal API calls
@MainActor
class DataCoordinator: ObservableObject {
    static let shared = DataCoordinator()
    
    // Published state
    @Published var isInitializing = true
    @Published var initialClipsReady = false
    
    // Shared data cache
    private(set) var trendingMovies: [Movie] = []
    private(set) var trendingTVShows: [TVShow] = []
    private(set) var popularMovies: [Movie] = []
    private(set) var topRatedMovies: [Movie] = []
    
    // Clips cache (managed by ClipsViewModel)
    var initialClips: [Clip] = []
    var additionalClips: [Clip] = []
    
    // Services
    private let tmdbService = TMDBService.shared
    
    // Track what's been fetched
    private var discoveryFetched = false
    private var usedMovieIds = Set<Int>()
    private var usedTVShowIds = Set<Int>()
    private var nextMoviePage = 2 // Start from page 2 for pagination
    private var nextTVPage = 2
    
    private init() {}
    
    // MARK: - App Launch (Parallel Tasks)
    
    /// Called on splash screen - runs discovery + initial clips in parallel, additional in background
    func initializeApp() async {
        print("🚀 [DataCoordinator] Starting app initialization...")
        let startTime = Date()

        // Run discovery + initial clips in parallel with timeout protection
        await withTaskGroup(of: Void.self) { group in
            // Discovery task
            group.addTask {
                await self.fetchDiscoveryContent()
            }

            // Initial clips task
            group.addTask {
                await self.fetchInitialClips()
            }

            // Wait for both tasks to complete
            await group.waitForAll()
        }

        let duration = Date().timeIntervalSince(startTime)
        print("✅ [DataCoordinator] Fast init complete in \(String(format: "%.2f", duration))s")
        print("   📊 Discovery: \(trendingMovies.count) movies, \(trendingTVShows.count) TV")
        print("   🎬 Initial clips: \(initialClips.count) ready")

        isInitializing = false
        initialClipsReady = true

        // Fetch additional clips in background (don't wait)
        Task.detached(priority: .background) {
            await self.fetchAdditionalClips()
        }
    }
    
    // MARK: - Discovery Content (Database Cache)
    
    /// Fetch all discovery content - uses database cache, refreshes if needed
    private func fetchDiscoveryContent() async {
        print("📺 [DataCoordinator] Checking discovery cache...")
        
        let discoveryCache = DiscoveryCacheService.shared
        
        do {
            // Check if cache needs refresh
            if await discoveryCache.needsRefresh() {
                print("🔄 [DataCoordinator] Cache expired, refreshing from TMDB...")
                try await discoveryCache.refreshContent()
            }
            
            // Get from cache (either DB or fresh)
            let content = try await discoveryCache.getDiscoveryContent()
            
            // Store for DataCoordinator's internal use (legacy support)
            self.trendingMovies = content.trending
            self.popularMovies = content.popular
            self.topRatedMovies = content.topRated
            self.trendingTVShows = content.tv
            
            discoveryFetched = true
            
            print("✅ [DataCoordinator] Discovery content ready from cache")
            
        } catch {
            print("❌ [DataCoordinator] Failed to fetch discovery: \(error)")
        }
    }
    
    /// Refresh discovery content (e.g., when language changes)
    func refreshDiscoveryContent() async {
        print("🔄 [DataCoordinator] Refreshing discovery content...")
        discoveryFetched = false
        await fetchDiscoveryContent()
    }
    
    /// Get discovery content for DiscoveryViewModel (instant, no API calls)
    func getDiscoveryContent() async -> (movies: [Movie], topRated: [Movie], popular: [Movie], tvShows: [TVShow])? {
        // Wait for discovery to be fetched if it's in progress
        if !discoveryFetched {
            await fetchDiscoveryContent()
        }
        
        guard discoveryFetched else { return nil }
        
        return (trendingMovies, topRatedMovies, popularMovies, trendingTVShows)
    }
    
    // MARK: - Initial Clips (5 for instant playback from DATABASE)
    
    /// Fetch 5 clips from DATABASE for INSTANT playback (super fast!)
    private func fetchInitialClips() async {
        print("🎬 [DataCoordinator] Fetching initial clips from DATABASE...")
        
        do {
            // Fetch directly from database (should be instant!)
            let dbService = DatabaseClipsService.shared
            let clips = try await dbService.fetchPersonalizedClips(count: 5)
            
            initialClips = clips
            
            if !clips.isEmpty {
                print("✅ [DataCoordinator] Initial clips ready from DB: \(clips.count)")
            } else {
                print("⚠️ [DataCoordinator] No clips in database yet")
            }
        } catch {
            print("❌ [DataCoordinator] Failed to fetch initial clips from DB: \(error)")
            initialClips = []
        }
    }
    
    // MARK: - Additional Clips (20 for background preload from DATABASE)
    
    /// Fetch more clips from DATABASE in background while user explores Discovery
    private func fetchAdditionalClips() async {
        print("🎬 [DataCoordinator] Fetching additional clips from DATABASE (background)...")
        
        do {
            // Fetch from database (fast!)
            let dbService = DatabaseClipsService.shared
            let clips = try await dbService.fetchPersonalizedClips(count: 20)
            
            await MainActor.run {
                self.additionalClips = clips
                print("✅ [DataCoordinator] Additional clips ready from DB: \(clips.count) (total: \(self.initialClips.count + clips.count))")
            }
        } catch {
            print("❌ [DataCoordinator] Failed to fetch additional clips from DB: \(error)")
            await MainActor.run {
                self.additionalClips = []
            }
        }
    }
    
    // MARK: - Pagination (Load More Clips)
    
    /// Fetch more clips for infinite scroll
    func fetchMoreClips(count: Int = 20) async -> [Clip] {
        print("🎬 [DataCoordinator] Fetching \(count) more clips (page \(nextMoviePage))...")
        
        do {
            // Fetch next pages of content
            async let movies = tmdbService.getTrendingMovies(timeWindow: .week, page: nextMoviePage)
            async let tv = tmdbService.getTrendingTVShows(timeWindow: .week, page: nextTVPage)
            
            let (moviesRes, tvRes) = try await (movies, tv)
            
            nextMoviePage += 1
            nextTVPage += 1
            
            let clips = await fetchClipsBatch(count: count, fromMovies: moviesRes.results, fromTV: tvRes.results)
            
            print("✅ [DataCoordinator] Pagination: fetched \(clips.count) clips")
            return clips
            
        } catch {
            print("❌ [DataCoordinator] Pagination failed: \(error)")
            return []
        }
    }
    
    // MARK: - Batch Clip Fetching (Optimized)
    
    /// Fetch clips in parallel batches (much faster than sequential)
    private func fetchClipsBatch(count: Int, fromMovies movies: [Movie], fromTV tvShows: [TVShow]) async -> [Clip] {
        var clips: [Clip] = []
        var seenClipIds = Set<String>() // Deduplicate by clip ID
        
        // Get unused movies and TV shows
        let unusedMovies = movies.filter { !usedMovieIds.contains($0.id) }
        let unusedTV = tvShows.filter { !usedTVShowIds.contains($0.id) }
        
        // Calculate how many from each source (70% movies, 30% TV)
        let movieCount = Int(Double(count) * 0.7)
        let tvCount = count - movieCount
        
        // Fetch clips in parallel with TaskGroup
        await withTaskGroup(of: (Clip?, Int, Bool).self) { group in
            // Add movie tasks (fetch 3x to account for failures + duplicates)
            for movie in unusedMovies.prefix(movieCount * 3) {
                group.addTask {
                    if let clip = await self.fetchClipForMovie(movie) {
                        return (clip, movie.id, true) // true = isMovie
                    }
                    return (nil, movie.id, true)
                }
            }
            
            // Add TV tasks
            for tvShow in unusedTV.prefix(tvCount * 3) {
                group.addTask {
                    if let clip = await self.fetchClipForTVShow(tvShow) {
                        return (clip, tvShow.id, false) // false = isTV
                    }
                    return (nil, tvShow.id, false)
                }
            }
            
            // Collect results with deduplication
            for await (clip, mediaId, isMovie) in group {
                if let clip = clip, !seenClipIds.contains(clip.id) {
                    clips.append(clip)
                    seenClipIds.insert(clip.id)
                    
                    // Mark as used
                    if isMovie {
                        usedMovieIds.insert(mediaId)
                    } else {
                        usedTVShowIds.insert(mediaId)
                    }
                    
                    // Stop when we have enough
                    if clips.count >= count {
                        break
                    }
                }
            }
        }
        
        clips.shuffle()
        return Array(clips.prefix(count))
    }
    
    /// Fetch a single clip for a movie (TMDB videos, then YouTube fallback)
    private func fetchClipForMovie(_ movie: Movie) async -> Clip? {
        // Add small delay to respect rate limits
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        // Try TMDB videos first (clips, trailers, teasers)
        do {
            let videosResponse = try await tmdbService.getMovieVideos(id: movie.id)

            // Smart filtering: Prefer official, high-quality videos
            let videos = videosResponse.results.filter { video in
                guard video.site == "YouTube" else { return false }

                // Prefer official videos (less likely to be removed)
                let isOfficial = video.official ?? false

                // Filter by type priority: Trailer > Teaser > Clip > Behind the Scenes
                let acceptedTypes = ["Trailer", "Teaser", "Clip", "Behind the Scenes"]
                let hasGoodType = acceptedTypes.contains(video.type)

                // Prefer larger videos (higher quality, more likely to be official)
                let hasGoodSize = (video.size ?? 0) >= 720

                return hasGoodType && (isOfficial || hasGoodSize)
            }

            if let video = videos.first {
                let clip = Clip(
                    id: "\(movie.id)-tmdb-\(video.key)",
                    movieId: movie.id,
                    tvShowId: nil,
                    title: movie.title,
                    description: video.name,
                    videoURL: "https://www.youtube.com/watch?v=\(video.key)",
                    videoId: video.key,
                    thumbnailURL: "https://img.youtube.com/vi/\(video.key)/hqdefault.jpg", // 480x360 - optimized
                    duration: 0,
                    likes: 0,
                    comments: 0,
                    createdAt: Date()
                )

                print("   ✅ TMDB clip found: \(movie.title)")
                return clip
            }
        } catch {
            print("   ⚠️ TMDB videos failed for \(movie.title): \(error.localizedDescription)")
        }

        // Fallback to YouTube search with timeout and retry
        do {
            let query = "\(movie.title) official trailer"
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return nil
            }

            let urlString = "https://www.googleapis.com/youtube/v3/search?part=snippet&q=\(encodedQuery)&type=video&videoDuration=short&maxResults=1&key=AIzaSyCh_tkrvBEGW6ALRvkAN-LYx1B3Cly1160"

            guard let url = URL(string: urlString) else { return nil }

            // Create URLSession with timeout
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = true
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                print("   ⚠️ YouTube API returned error for \(movie.title)")
                return nil
            }

            let decodedResponse = try JSONDecoder().decode(YouTubeSearchResponse.self, from: data)

            guard let item = decodedResponse.items.first else { return nil }

            let clip = Clip(
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

            print("   ✅ YouTube clip found: \(movie.title)")
            return clip

        } catch {
            print("   ❌ All sources failed for: \(movie.title) - \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Fetch a single clip for a TV show (TMDB videos, then YouTube fallback)
    private func fetchClipForTVShow(_ tvShow: TVShow) async -> Clip? {
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        // Try TMDB videos first
        do {
            let videosResponse = try await tmdbService.getTVShowVideos(id: tvShow.id)

            // Smart filtering: Prefer official, high-quality videos
            let videos = videosResponse.results.filter { video in
                guard video.site == "YouTube" else { return false }

                // Prefer official videos (less likely to be removed)
                let isOfficial = video.official ?? false

                // Filter by type priority
                let acceptedTypes = ["Trailer", "Teaser", "Clip", "Behind the Scenes"]
                let hasGoodType = acceptedTypes.contains(video.type)

                // Prefer larger videos (higher quality, more likely to be official)
                let hasGoodSize = (video.size ?? 0) >= 720

                return hasGoodType && (isOfficial || hasGoodSize)
            }

            if let video = videos.first {
                let clip = Clip(
                    id: "\(tvShow.id)-tmdb-\(video.key)",
                    movieId: nil,
                    tvShowId: tvShow.id,
                    title: tvShow.name,
                    description: video.name,
                    videoURL: "https://www.youtube.com/watch?v=\(video.key)",
                    videoId: video.key,
                    thumbnailURL: "https://img.youtube.com/vi/\(video.key)/hqdefault.jpg", // 480x360 - optimized
                    duration: 0,
                    likes: 0,
                    comments: 0,
                    createdAt: Date()
                )

                print("   ✅ TMDB clip found: \(tvShow.name)")
                return clip
            }
        } catch {
            print("   ⚠️ TMDB videos failed for \(tvShow.name): \(error.localizedDescription)")
        }

        // Fallback to YouTube search with timeout and retry
        do {
            let query = "\(tvShow.name) official trailer"
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return nil
            }

            let urlString = "https://www.googleapis.com/youtube/v3/search?part=snippet&q=\(encodedQuery)&type=video&videoDuration=short&maxResults=1&key=AIzaSyCh_tkrvBEGW6ALRvkAN-LYx1B3Cly1160"

            guard let url = URL(string: urlString) else { return nil }

            // Create URLSession with timeout
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = true
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                print("   ⚠️ YouTube API returned error for \(tvShow.name)")
                return nil
            }

            let decodedResponse = try JSONDecoder().decode(YouTubeSearchResponse.self, from: data)

            guard let item = decodedResponse.items.first else { return nil }

            let clip = Clip(
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

            print("   ✅ YouTube clip found: \(tvShow.name)")
            return clip

        } catch {
            print("   ❌ All sources failed for: \(tvShow.name) - \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Stats & Debug
    
    func getStats() -> String {
        """
        📊 DataCoordinator Stats:
        - Discovery: \(trendingMovies.count + popularMovies.count + topRatedMovies.count) movies, \(trendingTVShows.count) TV
        - Clips ready: \(initialClips.count) initial + \(additionalClips.count) additional
        - Used sources: \(usedMovieIds.count) movies, \(usedTVShowIds.count) TV
        - Next pages: Movie p\(nextMoviePage), TV p\(nextTVPage)
        """
    }
}

// YouTube models are in Core/Models/YouTubeModels.swift
