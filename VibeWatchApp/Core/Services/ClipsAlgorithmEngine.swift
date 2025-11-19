import Foundation

@MainActor
class ClipsAlgorithmEngine {
    static let shared = ClipsAlgorithmEngine()
    
    private let tmdbService = TMDBService.shared
    private let engagementTracker = UserEngagementTracker.shared
    
    // Track which pages we've fetched to avoid duplicates
    private var moviePagesFetched: Set<Int> = []
    private var tvPagesFetched: Set<Int> = []
    private var nextMoviePage = 1
    private var nextTVPage = 1
    
    // Genre IDs from TMDb
    private let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
        80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
        14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Science Fiction",
        10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western"
    ]
    
    // Classic movie IDs (curated list of must-watch movies)
    private let classicMovieIds: [Int] = [
        238,   // The Godfather
        278,   // The Shawshank Redemption
        240,   // The Godfather Part II
        424,   // Schindler's List
        19404, // Dilwale Dulhania Le Jayenge
        389,   // 12 Angry Men
        129,   // Spirited Away
        155,   // The Dark Knight
        13,    // Forrest Gump
        769,   // GoodFellas
        346,   // Seven
        12477, // Grave of the Fireflies
        637,   // Life Is Beautiful
        11216, // Cinema Paradiso
        533,   // The Silence of the Lambs
        680,   // Pulp Fiction
        122,   // The Lord of the Rings: The Return of the King
        120,   // The Lord of the Rings: The Fellowship of the Ring
        121,   // The Lord of the Rings: The Two Towers
        429,   // The Good, the Bad and the Ugly
    ]
    
    private init() {}
    
    // MARK: - Main Algorithm
    
    /// Fast version: Generate just 2 clips for instant display
    func generateQuickStartFeed() async throws -> [EnhancedClip] {
        print("⚡ Generating quick start feed (targeting 2 clips)...")
        let startTime = Date()
        
        // Fetch just trending movies and keep trying until we get 2 clips
        let moviesResponse = try await tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
        print("📊 Got \(moviesResponse.results.count) trending movies to try")
        
        var clips: [EnhancedClip] = []
        var triedCount = 0
        
        // Try up to 15 movies to ensure we get 2 clips with videos
        for movie in moviesResponse.results.prefix(15) {
            triedCount += 1
            
            if let movieClips = try? await fetchBestClipForMovie(movie), let clip = movieClips.first {
                clips.append(clip)
                print("✅ Got clip \(clips.count) from movie: \(movie.title)")
                
                if clips.count >= 2 {
                    print("🎯 Target reached: 2 clips secured!")
                    break // Stop as soon as we have 2
                }
            } else {
                print("⏭️ Movie '\(movie.title)' has no clips, trying next...")
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        print("✅ Quick start ready: \(clips.count)/2 clips in \(String(format: "%.2f", duration))s (tried \(triedCount) movies)")
        
        // If we still don't have 2, log a warning
        if clips.count < 2 {
            print("⚠️ WARNING: Only got \(clips.count) clip(s) after trying \(triedCount) movies!")
        }
        
        return clips
    }
    
    /// Tier 2: Fast feed - 20 clips in max 10 seconds with VARIETY
    func generateFastFeed() async throws -> [EnhancedClip] {
        print("⚡ Fast feed: Targeting 20 clips from diverse sources...")
        let startTime = Date()
        
        let todayTheme = getThematicDayBoost()
        let userProfile = getUserProfile()
        
        // Fetch from MULTIPLE pages for maximum variety - 4 pages total (2 movies + 2 TV)
        // This ensures we get clips from 30-40 different movies/TV shows for 20 clips
        async let moviesPage1 = fetchMoviesOptimized(page: 1, count: 15)
        async let moviesPage2 = fetchMoviesOptimized(page: 2, count: 15)
        async let tvPage1 = fetchTVShowsOptimized(page: 1, count: 15)
        async let tvPage2 = fetchTVShowsOptimized(page: 2, count: 15)
        
        let results = try await (moviesPage1, moviesPage2, tvPage1, tvPage2)
        var contentPool = results.0 + results.1 + results.2 + results.3
        
        print("📦 Fast feed: Fetched \(contentPool.count) clips in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
        print("📊 Source variety: ~\(contentPool.count) clips from multiple sources for final 20")
        
        // Quick scoring
        contentPool = quickScore(contentPool, userProfile: userProfile, themeBoost: todayTheme)
        
        // Log source IDs BEFORE diversity
        let beforeSourceIds = Set(contentPool.map { $0.clip.movieId ?? $0.clip.tvShowId ?? 0 })
        print("📊 Before diversity: \(contentPool.count) clips from \(beforeSourceIds.count) unique sources")
        print("📝 Source IDs: \(Array(beforeSourceIds).sorted())")
        
        // Diversity
        let diverseFeed = enforceDiversity(contentPool, targetCount: 20)
        
        // Log source IDs AFTER diversity
        let afterSourceIds = Set(diverseFeed.map { $0.clip.movieId ?? $0.clip.tvShowId ?? 0 })
        print("📊 After diversity: \(diverseFeed.count) clips from \(afterSourceIds.count) unique sources")
        print("📝 Final source IDs: \(Array(afterSourceIds).sorted())")
        
        let duration = Date().timeIntervalSince(startTime)
        print("✅ Fast feed: Generated \(diverseFeed.count) clips in \(String(format: "%.2f", duration))s")
        return Array(diverseFeed.prefix(20))
    }
    
    /// Tier 3: Extended feed - 50 clips for deep scrolling
    func generateExtendedFeed() async throws -> [EnhancedClip] {
        print("⚡ Extended feed: Generating 50 clips from NEW pages...")
        print("📄 Next pages: Movies \(nextMoviePage)-\(nextMoviePage+2), TV \(nextTVPage)-\(nextTVPage+2)")
        let startTime = Date()
        
        let todayTheme = getThematicDayBoost()
        let userProfile = getUserProfile()
        
        // Fetch from NEXT pages (not already fetched)
        var contentPool: [EnhancedClip] = []
        
        let moviePage1 = nextMoviePage
        let moviePage2 = nextMoviePage + 1
        let moviePage3 = nextMoviePage + 2
        let tvPage1 = nextTVPage
        let tvPage2 = nextTVPage + 1
        let tvPage3 = nextTVPage + 2
        
        // Parallel fetch multiple NEW pages
        async let page1 = fetchMoviesOptimized(page: moviePage1)
        async let page2 = fetchTVShowsOptimized(page: tvPage1)
        async let page3 = fetchMoviesOptimized(page: moviePage2)
        async let page4 = fetchTVShowsOptimized(page: tvPage2)
        async let page5 = fetchMoviesOptimized(page: moviePage3)
        async let page6 = fetchTVShowsOptimized(page: tvPage3)
        
        let results = try await (page1, page2, page3, page4, page5, page6)
        contentPool = results.0 + results.1 + results.2 + results.3 + results.4 + results.5
        
        // Mark these pages as fetched
        moviePagesFetched.insert(moviePage1)
        moviePagesFetched.insert(moviePage2)
        moviePagesFetched.insert(moviePage3)
        tvPagesFetched.insert(tvPage1)
        tvPagesFetched.insert(tvPage2)
        tvPagesFetched.insert(tvPage3)
        
        // Increment for next time
        nextMoviePage += 3
        nextTVPage += 3
        
        print("📦 Extended feed: Fetched \(contentPool.count) clips in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
        print("📄 Pages fetched so far: Movies \(moviePagesFetched.count), TV \(tvPagesFetched.count)")
        
        // Note: Deduplication removed - segmenter will handle all clips
        
        // Score and diversify
        contentPool = quickScore(contentPool, userProfile: userProfile, themeBoost: todayTheme)
        let diverseFeed = enforceDiversity(contentPool, targetCount: 50)
        
        let duration = Date().timeIntervalSince(startTime)
        print("✅ Extended feed: Generated \(diverseFeed.count) unique clips in \(String(format: "%.2f", duration))s")
        return Array(diverseFeed.prefix(50))
    }
    
    /// Legacy method for compatibility
    func generateSmartFeed(count: Int = 20) async throws -> [EnhancedClip] {
        // Redirect to fast feed for now
        return try await generateFastFeed()
    }
    
    /// Lightning-fast content fetching - parallel execution
    private func fetchContentFast() async throws -> [EnhancedClip] {
        // Fetch movies and TV shows IN PARALLEL
        async let moviesTask = fetchMoviesOptimized()
        async let tvTask = fetchTVShowsOptimized()
        
        let (movies, tvShows) = try await (moviesTask, tvTask)
        
        let allClips = movies + tvShows
        
        // Note: Deduplication removed - segmenter will handle all clips
        
        return allClips
    }
    
    /// Optimized movie fetching (PARALLEL)
    private func fetchMoviesOptimized(page: Int = 1, count: Int = 5) async throws -> [EnhancedClip] {
        let moviesResponse = try await tmdbService.getTrendingMovies(timeWindow: .week, page: page)
        
        print("🎬 [Page \(page)] Fetched \(moviesResponse.results.count) trending movies")
        
        // Take requested count
        let moviesToFetch = Array(moviesResponse.results.prefix(count))
        
        // Fetch ALL clips in parallel using TaskGroup
        return await withTaskGroup(of: (clip: EnhancedClip, movieId: Int)?.self) { group in
            for movie in moviesToFetch {
                group.addTask {
                    if let movieClips = try? await self._fetchBestClipForMovie(movie), !movieClips.isEmpty {
                        print("   ✅ Movie: \"\(movie.title)\" (ID: \(movie.id)) → Found clip")
                        return (movieClips[0], movie.id)
                    } else {
                        print("   ⏭️ Movie: \"\(movie.title)\" (ID: \(movie.id)) → No clips available")
                        return nil
                    }
                }
            }
            
            var clips: [EnhancedClip] = []
            var movieIds: Set<Int> = []
            for await result in group {
                if let result = result {
                    clips.append(result.clip)
                    movieIds.insert(result.movieId)
                }
            }
            print("🎯 [Page \(page)] Got \(clips.count) clips from \(movieIds.count) unique movies: \(Array(movieIds).sorted())")
            return clips
        }
    }
    
    /// Optimized TV fetching (PARALLEL)
    private func fetchTVShowsOptimized(page: Int = 1, count: Int = 5) async throws -> [EnhancedClip] {
        let tvResponse = try await tmdbService.getTrendingTVShows(timeWindow: .week, page: page)
        
        print("📺 [Page \(page)] Fetched \(tvResponse.results.count) trending TV shows")
        
        // Take requested count
        let tvShowsToFetch = Array(tvResponse.results.prefix(count))
        
        // Fetch ALL clips in parallel using TaskGroup
        return await withTaskGroup(of: (clip: EnhancedClip, tvId: Int)?.self) { group in
            for tvShow in tvShowsToFetch {
                group.addTask {
                    if let tvClips = try? await self.fetchBestClipForTVShow(tvShow), !tvClips.isEmpty {
                        print("   ✅ TV Show: \"\(tvShow.name)\" (ID: \(tvShow.id)) → Found clip")
                        return (tvClips[0], tvShow.id)
                    } else {
                        print("   ⏭️ TV Show: \"\(tvShow.name)\" (ID: \(tvShow.id)) → No clips available")
                        return nil
                    }
                }
            }
            
            var clips: [EnhancedClip] = []
            var tvIds: Set<Int> = []
            for await result in group {
                if let result = result {
                    clips.append(result.clip)
                    tvIds.insert(result.tvId)
                }
            }
            print("🎯 [Page \(page)] Got \(clips.count) clips from \(tvIds.count) unique TV shows: \(Array(tvIds).sorted())")
            return clips
        }
    }
    
    /// Public method for cache pre-loading
    func fetchBestClipForMovie(_ movie: Movie) async throws -> [EnhancedClip] {
        return try await _fetchBestClipForMovie(movie)
    }
    
    /// Quick scoring - simplified for speed (no complex calculations)
    private func quickScore(_ clips: [EnhancedClip], userProfile: UserProfile, themeBoost: ThematicDay) -> [EnhancedClip] {
        return clips.map { enhancedClip in
            var score: Double = 0
            
            // Base popularity (simple)
            score += enhancedClip.popularity * 0.01
            
            // User preferences (if available)
            if engagementTracker.hasAnyPreferences() {
                for genreId in enhancedClip.genreIds {
                    score += engagementTracker.getGenreScore(genreId)
                }
            }
            
            // Thematic day boost
            for genreId in enhancedClip.genreIds {
                if themeBoost.genreIds.contains(genreId) {
                    score += 10
                }
            }
            
            // Small random factor
            score += Double.random(in: 0...5)
            
            var scoredClip = enhancedClip
            scoredClip.algorithmScore = score
            return scoredClip
        }.sorted { $0.algorithmScore > $1.algorithmScore }
    }
    
    // MARK: - Content Fetching
    
    private func fetchDiverseContentPool() async throws -> [EnhancedClip] {
        var allClips: [EnhancedClip] = []
        
        // Optimized: Fetch just trending (faster, still diverse)
        let trendingClips = try await fetchTrendingContent()
        allClips.append(contentsOf: trendingClips)
        
        // Note: Deduplication removed - segmenter will handle all clips
        
        return allClips
    }
    
    private func fetchTrendingContent() async throws -> [EnhancedClip] {
        var clips: [EnhancedClip] = []
        
        // Fetch trending movies (reduced to 15 for speed)
        let moviesResponse = try await tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
        for movie in moviesResponse.results.prefix(15) {
            if let movieClips = try? await fetchBestClipForMovie(movie), !movieClips.isEmpty {
                clips.append(movieClips[0]) // Take first clip only
            }
        }
        
        // Fetch trending TV shows (reduced to 10 for speed)
        let tvResponse = try await tmdbService.getTrendingTVShows(timeWindow: .week, page: 1)
        for tvShow in tvResponse.results.prefix(10) {
            if let tvClips = try? await fetchBestClipForTVShow(tvShow), !tvClips.isEmpty {
                clips.append(tvClips[0]) // Take first clip only
            }
        }
        
        return clips
    }
    
    private func fetchPopularContent() async throws -> [EnhancedClip] {
        var clips: [EnhancedClip] = []
        
        let moviesResponse = try await tmdbService.getPopularMovies(page: 1)
        for movie in moviesResponse.results.prefix(15) {
            if let movieClips = try? await fetchBestClipForMovie(movie) {
                clips.append(contentsOf: movieClips)
            }
        }
        
        return clips
    }
    
    private func fetchTopRatedContent() async throws -> [EnhancedClip] {
        var clips: [EnhancedClip] = []
        
        let moviesResponse = try await tmdbService.getTopRatedMovies(page: 1)
        for movie in moviesResponse.results.prefix(10) {
            if let movieClips = try? await fetchBestClipForMovie(movie) {
                clips.append(contentsOf: movieClips)
            }
        }
        
        return clips
    }
    
    // MARK: - Clip Extraction
    
    private func _fetchBestClipForMovie(_ movie: Movie) async throws -> [EnhancedClip] {
        let videosResponse = try await tmdbService.getMovieVideos(id: movie.id)
        let clips = videosResponse.results.filter { $0.type == "Clip" && $0.site == "YouTube" }
        
        guard !clips.isEmpty else { return [] }
        
        // Pick best clip (safe unwrapping)
        guard let bestClip = clips.max(by: { $0.key.count < $1.key.count }) else {
            return []
        }
        
        let clip = Clip(
            id: "\(movie.id)-\(bestClip.key)",
            movieId: movie.id,
            tvShowId: nil,
            title: movie.title,
            description: bestClip.name,
            videoURL: "https://www.youtube.com/watch?v=\(bestClip.key)",
            videoId: bestClip.key,
            thumbnailURL: "https://img.youtube.com/vi/\(bestClip.key)/maxresdefault.jpg",
            duration: 0,
            likes: 0,
            comments: 0,
            createdAt: Date()
        )
        
        return [EnhancedClip(
            clip: clip,
            genreIds: movie.genreIds ?? [],
            voteAverage: movie.voteAverage,
            popularity: movie.popularity,
            releaseYear: extractYear(from: movie.releaseDate),
            isClassic: false,
            qualityScore: calculateQualityScore(clip: bestClip, movie: movie)
        )]
    }
    
    private func fetchBestClipForTVShow(_ tvShow: TVShow) async throws -> [EnhancedClip] {
        let videosResponse = try await tmdbService.getTVShowVideos(id: tvShow.id)
        let clips = videosResponse.results.filter { $0.type == "Clip" && $0.site == "YouTube" }
        
        guard !clips.isEmpty else { return [] }
        
        guard let bestClip = clips.max(by: { $0.key.count < $1.key.count }) else {
            return []
        }
        
        let clip = Clip(
            id: "\(tvShow.id)-\(bestClip.key)",
            movieId: nil,
            tvShowId: tvShow.id,
            title: tvShow.name,
            description: bestClip.name,
            videoURL: "https://www.youtube.com/watch?v=\(bestClip.key)",
            videoId: bestClip.key,
            thumbnailURL: "https://img.youtube.com/vi/\(bestClip.key)/maxresdefault.jpg",
            duration: 0,
            likes: 0,
            comments: 0,
            createdAt: Date()
        )
        
        return [EnhancedClip(
            clip: clip,
            genreIds: tvShow.genreIds ?? [],
            voteAverage: tvShow.voteAverage,
            popularity: tvShow.popularity,
            releaseYear: extractYear(from: tvShow.firstAirDate),
            isClassic: false,
            qualityScore: calculateQualityScore(clip: bestClip, tvShow: tvShow)
        )]
    }
    
    // MARK: - Scoring System
    
    private func scoreClips(_ clips: [EnhancedClip], userProfile: UserProfile, themeBoost: ThematicDay) -> [EnhancedClip] {
        return clips.map { enhancedClip in
            var score: Double = 0
            
            // Base quality score
            score += enhancedClip.qualityScore * 10
            
            // Trending weight (40% from trending, 30% from popular, 30% from top rated)
            score += enhancedClip.popularity * 0.01
            
            // User personalization (if they have preferences)
            if engagementTracker.hasAnyPreferences() {
                for genreId in enhancedClip.genreIds {
                    let genreScore = engagementTracker.getGenreScore(genreId)
                    score += genreScore * 2 // Strong weight on user preferences
                }
                
                // Movie-specific preference
                if let movieId = enhancedClip.clip.movieId {
                    score += engagementTracker.getMovieScore(movieId) * 3
                } else if let tvShowId = enhancedClip.clip.tvShowId {
                    score += engagementTracker.getMovieScore(tvShowId) * 3
                }
            } else {
                // Cold start: use industry averages
                score += userProfile.industryAverageScore(for: enhancedClip.genreIds)
            }
            
            // Thematic day boost
            for genreId in enhancedClip.genreIds {
                if themeBoost.genreIds.contains(genreId) {
                    score += themeBoost.boostAmount
                }
            }
            
            // Hot streak boost (high energy content)
            if engagementTracker.isInHotStreak {
                if enhancedClip.genreIds.contains(28) || // Action
                   enhancedClip.genreIds.contains(53) {  // Thriller
                    score += 20 // Boost exciting content during hot streaks
                }
            }
            
            // Random factor (20% randomness to avoid pure echo chamber)
            score += Double.random(in: 0...15)
            
            var scoredClip = enhancedClip
            scoredClip.algorithmScore = score
            return scoredClip
        }.sorted { $0.algorithmScore > $1.algorithmScore }
    }
    
    // MARK: - Diversity Enforcement
    
    private func enforceDiversity(_ clips: [EnhancedClip], targetCount: Int) -> [EnhancedClip] {
        var diverseFeed: [EnhancedClip] = []
        var recentGenres: [Int] = []
        var recentMovies: Set<Int> = []
        var movieCount = 0
        var tvCount = 0
        
        for clip in clips {
            guard diverseFeed.count < targetCount else { break }
            
            // Rule 1: No more than 3 clips from same genre in last 10 clips
            let recentGenreCount = recentGenres.suffix(10).filter { clip.genreIds.contains($0) }.count
            if recentGenreCount >= 3 {
                continue // Skip this clip
            }
            
            // Rule 2: One clip per movie/show
            let mediaId = clip.clip.movieId ?? clip.clip.tvShowId ?? 0
            if recentMovies.contains(mediaId) {
                continue
            }
            
            // Rule 3: Balance movies vs TV shows (roughly 60/40 split)
            if clip.clip.movieId != nil {
                if movieCount >= Int(Double(targetCount) * 0.65) {
                    continue
                }
                movieCount += 1
            } else {
                if tvCount >= Int(Double(targetCount) * 0.35) {
                    continue
                }
                tvCount += 1
            }
            
            // Add clip to feed
            diverseFeed.append(clip)
            recentMovies.insert(mediaId)
            
            // Track genres for diversity
            if let primaryGenre = clip.genreIds.first {
                recentGenres.append(primaryGenre)
            }
        }
        
        return diverseFeed
    }
    
    // MARK: - Classic Injection
    
    private func injectClassics(_ clips: [EnhancedClip], every: Int) -> [EnhancedClip] {
        var finalFeed = clips
        var insertionIndex = every - 1
        
        // Shuffle classics for variety
        let shuffledClassics = classicMovieIds.shuffled()
        var classicIndex = 0
        
        while insertionIndex < finalFeed.count && classicIndex < shuffledClassics.count {
            let classicId = shuffledClassics[classicIndex]
            
            // Try to fetch classic clip
            Task {
                do {
                    let movie = try await tmdbService.getMovieDetails(id: classicId)
                    if let classicClips = try? await fetchBestClipForMovie(movie) {
                        var classicClip = classicClips.first!
                        classicClip.isClassic = true
                        
                        // Insert at position
                        if insertionIndex < finalFeed.count {
                            finalFeed.insert(classicClip, at: insertionIndex)
                        }
                    }
                } catch {
                    print("⚠️ Could not fetch classic movie \(classicId)")
                }
            }
            
            insertionIndex += every
            classicIndex += 1
        }
        
        return finalFeed
    }
    
    // MARK: - Thematic Days
    
    private func getThematicDayBoost() -> ThematicDay {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date())
        
        switch weekday {
        case 2: // Monday
            return ThematicDay(name: "Action Monday", genreIds: [28, 12], boostAmount: 25)
        case 3: // Tuesday
            return ThematicDay(name: "Throwback Tuesday", genreIds: [], boostAmount: 30, isClassicDay: true)
        case 4: // Wednesday
            return ThematicDay(name: "Wild Card Wednesday", genreIds: [878, 14, 27], boostAmount: 20)
        case 5: // Thursday
            return ThematicDay(name: "Thriller Thursday", genreIds: [53, 9648, 80], boostAmount: 25)
        case 6: // Friday
            return ThematicDay(name: "Fun Friday", genreIds: [35, 10749], boostAmount: 25)
        case 7: // Saturday
            return ThematicDay(name: "Blockbuster Saturday", genreIds: [28, 878, 12], boostAmount: 20)
        case 1: // Sunday
            return ThematicDay(name: "Chill Sunday", genreIds: [18, 10751, 16], boostAmount: 25)
        default:
            return ThematicDay(name: "Regular Day", genreIds: [], boostAmount: 0)
        }
    }
    
    // MARK: - User Profile
    
    private func getUserProfile() -> UserProfile {
        if engagementTracker.hasAnyPreferences() {
            let topGenres = engagementTracker.getTopGenres(limit: 5)
            return UserProfile(
                hasPreferences: true,
                topGenres: topGenres,
                demographicGroup: .mixed
            )
        } else {
            // Cold start: use industry averages
            return UserProfile(
                hasPreferences: false,
                topGenres: [],
                demographicGroup: .genZ // Default to Gen Z preferences
            )
        }
    }
    
    // MARK: - Helpers
    
    private func calculateQualityScore(clip: Video, movie: Movie) -> Double {
        var score: Double = 0
        
        // Prefer official clips (safely unwrap optional)
        if clip.official == true {
            score += 2
        }
        
        // Video rating
        score += (movie.voteAverage) / 2
        
        // Description quality
        if !clip.name.lowercased().contains("clip") &&
           !clip.name.lowercased().contains("scene") {
            score += 1 // Has descriptive name
        }
        
        return score
    }
    
    private func calculateQualityScore(clip: Video, tvShow: TVShow) -> Double {
        var score: Double = 0
        
        // Prefer official clips (safely unwrap optional)
        if clip.official == true {
            score += 2
        }
        
        score += (tvShow.voteAverage) / 2
        
        return score
    }
    
    private func extractYear(from dateString: String?) -> Int? {
        guard let dateString = dateString, dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }
}

// MARK: - Supporting Models

struct EnhancedClip {
    var clip: Clip
    let genreIds: [Int]
    let voteAverage: Double
    let popularity: Double
    let releaseYear: Int?
    var isClassic: Bool
    let qualityScore: Double
    var algorithmScore: Double = 0
}

struct ThematicDay {
    let name: String
    let genreIds: [Int]
    let boostAmount: Double
    var isClassicDay: Bool = false
}

struct UserProfile {
    let hasPreferences: Bool
    let topGenres: [Int]
    let demographicGroup: DemographicGroup
    
    func industryAverageScore(for genreIds: [Int]) -> Double {
        var score: Double = 0
        
        switch demographicGroup {
        case .genZ:
            // Gen Z prefers: Action, Horror, Comedy, Sci-Fi
            if genreIds.contains(28) { score += 5 } // Action
            if genreIds.contains(27) { score += 5 } // Horror
            if genreIds.contains(35) { score += 4 } // Comedy
            if genreIds.contains(878) { score += 4 } // Sci-Fi
            
        case .millennial:
            // Millennials prefer: Drama, Thriller, Comedy
            if genreIds.contains(18) { score += 5 } // Drama
            if genreIds.contains(53) { score += 5 } // Thriller
            if genreIds.contains(35) { score += 4 } // Comedy
            if genreIds.contains(10749) { score += 3 } // Romance
            
        case .genX:
            // Gen X prefers: Action, Crime, Classics
            if genreIds.contains(28) { score += 4 } // Action
            if genreIds.contains(80) { score += 5 } // Crime
            if genreIds.contains(18) { score += 4 } // Drama
            
        case .mixed:
            // Balanced approach
            score += 3
        }
        
        return score
    }
}

enum DemographicGroup {
    case genZ
    case millennial
    case genX
    case mixed
}
