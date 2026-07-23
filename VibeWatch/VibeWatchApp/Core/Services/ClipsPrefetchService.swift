import Foundation
import Supabase

/// Service responsible for pre-fetching and caching clips to Supabase
@MainActor
class ClipsPrefetchService: ObservableObject {
    static let shared = ClipsPrefetchService()
    
    var isFetching = false
    var lastFetchDate: Date?
    var cachedClipsCount: Int = 0
    private var fetchProgress: Double = 0.0
    
    private let supabase = SupabaseService.shared
    private let tmdbService = TMDBService.shared
    // The YouTube key now lives only in YouTubeSearchClient, which owns the quota gate.
    
    private let userDefaults = UserDefaults.standard
    private let lastFetchKey = "lastClipsPrefetchDate"
    private let cachedCountKey = "cachedClipsCount"
    
    private init() {
        loadLastFetchDate()
    }
    
    // MARK: - YouTube Video Validation
    
    /// Validate if a YouTube video is playable and embeddable
    private func isVideoValid(videoId: String) async -> Bool {
        do {
            // videos.list costs 1 unit, not 100 — but it shares the project budget, so it goes
            // through the same gate. See YouTubeSearchClient.
            guard let video = try await YouTubeSearchClient.shared.videoDetails(id: videoId) else {
                Logger.warning("[Validation] Video \(videoId): Not found")
                return false
            }
            
            // Check if video is embeddable
            guard video.status.embeddable else {
                Logger.warning("[Validation] Video \(videoId): Not embeddable")
                return false
            }
            
            // Check if video has age restrictions that block embedding
            if let ageGated = video.contentDetails.contentRating.ytRating, ageGated == "ytAgeRestricted" {
                Logger.warning("[Validation] Video \(videoId): Age restricted")
                return false
            }
            
            // Check upload status
            guard video.status.uploadStatus == "processed" else {
                Logger.warning("[Validation] Video \(videoId): Not processed (status: \(video.status.uploadStatus))")
                return false
            }
            
            // Check privacy status
            guard video.status.privacyStatus == "public" else {
                Logger.warning("[Validation] Video \(videoId): Not public (status: \(video.status.privacyStatus))")
                return false
            }
            
            Logger.debug("[Validation] Video \(videoId): Valid")
            return true
            
        } catch {
            Logger.error("[Validation] Video \(videoId): Validation failed - \(error)")
            return false
        }
    }
    
    // MARK: - Main Pre-fetch Function
    
    /// Whether the heavy clip prefetch (YouTube validation + DB writes) is allowed to run.
    ///
    /// Fase 4 (3.1 — batteria): il prefetch gira SOLO su Wi-Fi e fuori da Low-Power Mode.
    /// Funzione pura (no I/O) per testabilità; la composizione con l'ambiente reale
    /// (NetworkMonitor + ProcessInfo) avviene in `prefetchClips`.
    nonisolated static func isPrefetchAllowed(isWiFi: Bool, isLowPowerMode: Bool) -> Bool {
        isWiFi && !isLowPowerMode
    }

    /// Pre-fetch clips and store in Supabase
    /// - Parameter targetCount: How many VALID clips to store in DB (default: 100)
    /// - Returns: Number of clips successfully cached
    ///
    /// Fase 4 (3.1): target abbassato da 800 a 100 (incrementale: fetcha solo `target - currentDBCount`)
    /// e gating Wi-Fi/Low-Power. Su pool vuoto valida ~100 invece di 800 (8× meno YouTube/TMDB);
    /// su pool già pieno ritorna subito.
    @discardableResult
    func prefetchClips(targetCount: Int = 100) async throws -> Int {
        guard !isFetching else {
            Logger.warning("[ClipsPrefetch] Already fetching, skipping...")
            return 0
        }

        // Gate batteria/rete: solo Wi-Fi + non Low-Power Mode.
        let allowed = Self.isPrefetchAllowed(
            isWiFi: await NetworkMonitor.shared.isOnWiFi(),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        guard allowed else {
            Logger.info("[ClipsPrefetch] Skipping prefetch — not on Wi-Fi or Low-Power Mode enabled")
            return 0
        }

        Logger.info("[ClipsPrefetch] Starting pre-fetch - Target: \(targetCount) VALID clips in DB...")
        isFetching = true
        fetchProgress = 0.0
        
        do {
            // 1. Check current DB count
            let currentDBCount = try await getValidClipsCountInDB()
            Logger.debug("[ClipsPrefetch] Current DB count: \(currentDBCount) / \(targetCount)")
            
            if currentDBCount >= targetCount {
                Logger.info("[ClipsPrefetch] Target already met! (\(currentDBCount) clips)")
                isFetching = false
                cachedClipsCount = currentDBCount
                return currentDBCount
            }
            
            let needed = targetCount - currentDBCount
            Logger.debug("[ClipsPrefetch] Need \(needed) more valid clips")
            
            // 2. Fetch and validate clips until we reach target
            var validClipsStored = currentDBCount
            var attemptedClips = 0
            let maxAttempts = needed * 3 // Fetch up to 3x more to account for invalid videos
            
            // Fetch movies and TV shows
            let movies = try await fetchPopularMovies(count: needed)
            let tvShows = try await fetchPopularTVShows(count: needed)
            
            Logger.debug("[ClipsPrefetch] Fetched \(movies.count) movies, \(tvShows.count) TV shows")
            
            // Process movies
            for movie in movies {
                if validClipsStored >= targetCount {
                    break
                }
                
                let clips = try await fetchAndValidateClipsForMovie(movie)
                if !clips.isEmpty {
                    let stored = try await storeClipsInSupabase(clips)
                    validClipsStored += stored
                    
                    fetchProgress = Double(validClipsStored) / Double(targetCount)
                    Logger.debug("[ClipsPrefetch] Progress: \(validClipsStored)/\(targetCount) (\(Int(fetchProgress * 100))%)")
                }
                
                attemptedClips += 1
                if attemptedClips >= maxAttempts {
                    break
                }
            }
            
            // Process TV shows
            for tvShow in tvShows {
                if validClipsStored >= targetCount {
                    break
                }
                
                let clips = try await fetchAndValidateClipsForTVShow(tvShow)
                if !clips.isEmpty {
                    let stored = try await storeClipsInSupabase(clips)
                    validClipsStored += stored
                    
                    fetchProgress = Double(validClipsStored) / Double(targetCount)
                    Logger.debug("[ClipsPrefetch] Progress: \(validClipsStored)/\(targetCount) (\(Int(fetchProgress * 100))%)")
                }
                
                attemptedClips += 1
                if attemptedClips >= maxAttempts {
                    break
                }
            }
            
            // 3. Final verification
            let finalCount = try await getValidClipsCountInDB()
            
            // 4. Update metadata
            lastFetchDate = Date()
            cachedClipsCount = finalCount
            saveLastFetchDate()
            
            isFetching = false
            fetchProgress = 1.0
            
            Logger.info("[ClipsPrefetch] Completed! DB now has \(finalCount) valid clips")
            Logger.debug("[ClipsPrefetch] Target: \(targetCount), Achieved: \(finalCount), Success: \(finalCount >= targetCount ? "YES" : "NO")")
            
            return finalCount
            
        } catch {
            isFetching = false
            fetchProgress = 0.0
            Logger.error("[ClipsPrefetch] Error: \(error)")
            throw error
        }
    }
    
    // MARK: - DB Count Verification
    
    /// Get actual count of valid clips in database
    private func getValidClipsCountInDB() async throws -> Int {
        guard let client = supabase.client else {
            throw ClipsPrefetchError.supabaseNotConfigured
        }
        
        let response: [ClipCountRow] = try await client
            .from("clips")
            .select("id", head: false, count: .exact)
            .eq("is_active", value: true)
            .execute()
            .value
        
        // The count is in the response metadata, but we can also just count the array
        return response.count
    }
    
    // MARK: - Check if Fetch Needed
    
    /// Check if we need to fetch today (daily 800 clips for first 7 days)
    func shouldFetchToday() -> Bool {
        guard let lastFetch = lastFetchDate else {
            return true // Never fetched before
        }
        
        // Check if last fetch was yesterday or earlier
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(lastFetch)
        
        // During first week: always return true if not fetched today
        let installDate = getInstallDate()
        let daysSinceInstall = calendar.dateComponents([.day], from: installDate, to: Date()).day ?? 1
        
        if daysSinceInstall <= 7 {
            return !isToday // Fetch daily during first week
        }
        
        // After first week: rely on weekly refresh
        return false
    }
    
    /// Get install date
    private func getInstallDate() -> Date {
        let key = "appInstallDate"
        if let existing = UserDefaults.standard.object(forKey: key) as? Date {
            return existing
        }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        UserDefaults.standard.set(yesterday, forKey: key)
        return yesterday
    }
    
    /// Check if we need a weekly refresh
    func shouldRefreshWeekly() -> Bool {
        guard let lastFetch = lastFetchDate else {
            return true // Never fetched before
        }
        
        let calendar = Calendar.current
        let daysSinceLastFetch = calendar.dateComponents([.day], from: lastFetch, to: Date()).day ?? 0
        
        return daysSinceLastFetch >= 7
    }
    
    /// Perform weekly refresh - add new clips without removing old ones
    @discardableResult
    func performWeeklyRefresh(additionalClips: Int = 200) async throws -> Int {
        guard !isFetching else {
            Logger.warning("[ClipsPrefetch] Already fetching, skipping weekly refresh...")
            return 0
        }
        
        Logger.debug("[ClipsPrefetch] Starting weekly refresh - adding \(additionalClips) new clips...")
        isFetching = true
        fetchProgress = 0.0
        
        do {
            var validClipsStored = 0
            var attemptedClips = 0
            let maxAttempts = additionalClips * 3
            
            // Fetch latest/trending movies and TV shows
            let movies = try await fetchTrendingMovies(count: additionalClips / 2)
            let tvShows = try await fetchTrendingTVShows(count: additionalClips / 2)
            
            Logger.debug("[WeeklyRefresh] Fetched \(movies.count) trending movies, \(tvShows.count) TV shows")
            
            // Process movies
            for movie in movies {
                if validClipsStored >= additionalClips {
                    break
                }
                
                let clips = try await fetchAndValidateClipsForMovie(movie)
                if !clips.isEmpty {
                    let stored = try await storeClipsInSupabase(clips)
                    validClipsStored += stored
                    
                    fetchProgress = Double(validClipsStored) / Double(additionalClips)
                    Logger.debug("[ClipsPrefetch] Refresh Progress: \(validClipsStored)/\(additionalClips) (\(Int(fetchProgress * 100))%)")
                }
                
                attemptedClips += 1
                if attemptedClips >= maxAttempts {
                    break
                }
            }
            
            // Process TV shows
            for tvShow in tvShows {
                if validClipsStored >= additionalClips {
                    break
                }
                
                let clips = try await fetchAndValidateClipsForTVShow(tvShow)
                if !clips.isEmpty {
                    let stored = try await storeClipsInSupabase(clips)
                    validClipsStored += stored
                    
                    fetchProgress = Double(validClipsStored) / Double(additionalClips)
                    Logger.debug("[ClipsPrefetch] Refresh Progress: \(validClipsStored)/\(additionalClips) (\(Int(fetchProgress * 100))%)")
                }
                
                attemptedClips += 1
                if attemptedClips >= maxAttempts {
                    break
                }
            }
            
            // Update metadata
            let finalCount = try await getValidClipsCountInDB()
            lastFetchDate = Date()
            cachedClipsCount = finalCount
            saveLastFetchDate()
            
            isFetching = false
            fetchProgress = 1.0
            
            Logger.info("[WeeklyRefresh] Completed! Added \(validClipsStored) new clips. Total in DB: \(finalCount)")
            
            return validClipsStored
            
        } catch {
            isFetching = false
            fetchProgress = 0.0
            Logger.error("[WeeklyRefresh] Error: \(error)")
            throw error
        }
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
    
    // MARK: - Trending Content (for weekly refresh)
    
    private func fetchTrendingMovies(count: Int) async throws -> [Movie] {
        var allMovies: [Movie] = []
        let pages = min(count / 20, 10) // Fewer pages for trending
        
        for page in 1...pages {
            // Use trending/movie/week endpoint for freshest content
            let response = try await tmdbService.getTrendingMovies(timeWindow: .week, page: page)
            allMovies.append(contentsOf: response.results)
            
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        return Array(allMovies.prefix(count))
    }
    
    private func fetchTrendingTVShows(count: Int) async throws -> [TVShow] {
        var allShows: [TVShow] = []
        let pages = min(count / 20, 10)
        
        for page in 1...pages {
            let response = try await tmdbService.getTrendingTVShows(timeWindow: .week, page: page)
            allShows.append(contentsOf: response.results)
            
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        return Array(allShows.prefix(count))
    }
    
    // MARK: - Fetch and Validate Clips for Media
    
    /// Fetch clips for a movie and validate each video
    private func fetchAndValidateClipsForMovie(_ movie: Movie) async throws -> [CachedClip] {
        var validClips: [CachedClip] = []
        
        // Get videos from TMDB
        let videosResponse = try await tmdbService.getMovieVideos(id: movie.id)
        let youtubeVideos = videosResponse.results.filter { $0.site == "YouTube" }
        
        for video in youtubeVideos.prefix(5) { // Try up to 5, validate to get 2-3 valid ones
            // Validate video before creating clip
            let isValid = await isVideoValid(videoId: video.key)
            
            if !isValid {
                Logger.debug("[ClipsPrefetch] Skipping invalid video: \(video.key) for movie: \(movie.title)")
                continue
            }
            
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
                youtubeViews: 0,
                qualityScore: 0.5
            )
            
            validClips.append(cachedClip)
            
            // Stop after getting 2-3 valid clips per movie
            if validClips.count >= 3 {
                break
            }
            
            // Small delay to avoid rate limiting YouTube API
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        
        return validClips
    }
    
    /// Fetch clips for a TV show and validate each video
    private func fetchAndValidateClipsForTVShow(_ tvShow: TVShow) async throws -> [CachedClip] {
        var validClips: [CachedClip] = []
        
        let videosResponse = try await tmdbService.getTVShowVideos(id: tvShow.id)
        let youtubeVideos = videosResponse.results.filter { $0.site == "YouTube" }
        
        for video in youtubeVideos.prefix(5) { // Try up to 5, validate to get 2-3 valid ones
            // Validate video before creating clip
            let isValid = await isVideoValid(videoId: video.key)
            
            if !isValid {
                Logger.debug("[ClipsPrefetch] Skipping invalid video: \(video.key) for TV: \(tvShow.name)")
                continue
            }
            
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
            
            validClips.append(cachedClip)
            
            // Stop after getting 2-3 valid clips per TV show
            if validClips.count >= 3 {
                break
            }
            
            // Small delay to avoid rate limiting
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        
        return validClips
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
                Logger.debug("[ClipsPrefetch] Stored batch: \(storedCount)/\(clips.count)")
                
            } catch {
                // If upsert fails due to RLS, try insert without conflict check
                Logger.warning("[ClipsPrefetch] Upsert failed, trying insert: \(error)")
                
                do {
                    let _: [CachedClip] = try await client
                        .from("clips")
                        .insert(batch)
                        .execute()
                        .value
                    
                    storedCount += batch.count
                    Logger.debug("[ClipsPrefetch] Inserted batch: \(storedCount)/\(clips.count)")
                } catch {
                    Logger.error("[ClipsPrefetch] Batch insert also failed: \(error)")
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

// MARK: - Database Count Model

private struct ClipCountRow: Codable {
    let id: UUID
}
