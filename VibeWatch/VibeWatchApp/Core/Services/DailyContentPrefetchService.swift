import Foundation

/// Service for daily prefetching of movie/TV content for PRO users
/// Automatically caches all trending content daily for offline viewing
///
/// PRO FEATURE: Only available for subscribed users
/// - Prefetches trending movies & TV shows daily
/// - Clears previous day's cache automatically
/// - Enables full offline browsing for PRO users
@MainActor
class DailyContentPrefetchService: ObservableObject {
    static let shared = DailyContentPrefetchService()

    @Published var isPrefetching = false
    @Published var prefetchProgress: Double = 0
    @Published var lastPrefetchDate: Date?

    private let tmdbService = TMDBService.shared
    private let detailCache = DetailCacheService.shared
    private let quotaService = ClipQuotaService.shared
    private let imageCache = ImageCacheService.shared

    private let userDefaults = UserDefaults.standard
    private let lastPrefetchKey = "lastDailyPrefetchDate"
    private let prefetchEnabledKey = "dailyPrefetchEnabled"

    // TMDB image base URLs (must match URLs used in models/views)
    private let tmdbPosterBaseURL = "https://image.tmdb.org/t/p/w500"       // Matches Movie/TVShow.posterURL
    private let tmdbBackdropBaseURL = "https://image.tmdb.org/t/p/w1280"    // Matches Movie/TVShow.backdropURL
    private let tmdbProfileBaseURL = "https://image.tmdb.org/t/p/w185"      // Matches Cast.profileURL
    private let tmdbLogoBaseURL = "https://image.tmdb.org/t/p/original"     // Matches Provider.logoURL

    private init() {
        // Load last prefetch date
        if let date = userDefaults.object(forKey: lastPrefetchKey) as? Date {
            lastPrefetchDate = date
        }
    }

    // MARK: - Public API

    /// Check if daily prefetch is needed and execute if PRO user
    func checkAndExecuteDailyPrefetch() async {
        await executeDailyPrefetch(force: false)
    }

    /// Execute daily prefetch with option to force (ignore daily limit)
    func executeDailyPrefetch(force: Bool = false) async {
        // Only for PRO users
        guard await quotaService.checkIsProUser() else {
            Logger.debug("[DailyPrefetch] Skipping - Non-PRO user")
            return
        }

        // Check user prefetch preference from UserDefaults
        let prefetchOption = imageCache.getCurrentImagePrefetchOption()
        let shouldPrefetch = await imageCache.shouldPrefetchImages(preference: prefetchOption)

        guard shouldPrefetch else {
            Logger.debug("[DailyPrefetch] Skipping - User disabled image prefetching")
            return
        }

        // Check if prefetch is needed (once per day) - unless forced
        guard force || shouldPrefetchToday() else {
            if force {
                Logger.debug("[DailyPrefetch] Forced prefetch - ignoring daily limit")
            }
            Logger.debug("[DailyPrefetch] Already prefetched today")
            return
        }

        Logger.info("[DailyPrefetch] Starting daily content prefetch...")
        await executeDailyPrefetchInternal()
    }
    
    /// Manually trigger prefetch (for testing or user request)
    func manualPrefetch() async {
        guard await quotaService.checkIsProUser() else {
            Logger.error("[DailyPrefetch] Manual prefetch failed - Non-PRO user")
            return
        }

        await executeDailyPrefetchInternal()
    }

    /// Enable/disable daily prefetch
    func setEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: prefetchEnabledKey)
        Logger.debug("[DailyPrefetch] Daily prefetch \(enabled ? "enabled" : "disabled")")
    }

    func isEnabled() -> Bool {
        return userDefaults.bool(forKey: prefetchEnabledKey)
    }

    // MARK: - Private Helpers

    private func shouldPrefetchToday() -> Bool {
        guard let lastPrefetch = lastPrefetchDate else {
            return true // Never prefetched before
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastPrefetchDay = calendar.startOfDay(for: lastPrefetch)

        return today > lastPrefetchDay
    }

    private func executeDailyPrefetchInternal() async {
        let startTime = Date()
        isPrefetching = true
        prefetchProgress = 0

        do {
            // Step 1: Clear yesterday's cache (5%)
            Logger.debug("[DailyPrefetch] Clearing yesterday's cache...")
            try await detailCache.clearAllCache()
            prefetchProgress = 0.05
            Logger.debug("[DailyPrefetch] Old cache cleared")

            // Step 2: Get ALL discovery content from DiscoveryCacheService (10%)
            Logger.debug("[DailyPrefetch] Fetching ALL discovery content...")
            let discoveryCache = DiscoveryCacheService.shared
            let (trending, popular, topRated, tvShows) = try await discoveryCache.getDiscoveryContent()

            // Combine all unique movies
            var allMovies = Set<Movie>()
            allMovies.formUnion(trending)
            allMovies.formUnion(popular)
            allMovies.formUnion(topRated)
            let uniqueMovies = Array(allMovies)

            prefetchProgress = 0.1
            Logger.debug("[DailyPrefetch] Fetched \(uniqueMovies.count) movies, \(tvShows.count) TV shows")

            // Step 3: Cache all movie details (50%)
            Logger.debug("[DailyPrefetch] Caching movie details...")
            await cacheMovieDetails(uniqueMovies, progressStart: 0.1, progressEnd: 0.5)
            prefetchProgress = 0.5
            Logger.debug("[DailyPrefetch] Cached \(uniqueMovies.count) movie details")

            // Step 4: Cache all TV show details (100%)
            Logger.debug("[DailyPrefetch] Caching TV show details...")
            await cacheTVShowDetails(tvShows, progressStart: 0.5, progressEnd: 1.0)
            prefetchProgress = 1.0
            Logger.debug("[DailyPrefetch] Cached \(tvShows.count) TV show details")

            // Mark as complete
            let duration = Date().timeIntervalSince(startTime)
            lastPrefetchDate = Date()
            userDefaults.set(Date(), forKey: lastPrefetchKey)
            isPrefetching = false

            Logger.info("[DailyPrefetch] Complete in \(String(format: "%.2f", duration))s")
            Logger.debug("[DailyPrefetch] Total cached: \(uniqueMovies.count) movies + \(tvShows.count) TV shows")

        } catch {
            Logger.error("[DailyPrefetch] Failed: \(error.localizedDescription)")
            isPrefetching = false
            prefetchProgress = 0
        }
    }

    private func cacheMovieDetails(_ movies: [Movie], progressStart: Double = 0, progressEnd: Double = 1) async {
        let totalMovies = movies.count
        guard totalMovies > 0 else { return }

        var cached = 0

        for (index, movie) in movies.enumerated() {
            do {
                // Fetch full details
                async let detailsTask = tmdbService.getMovieDetails(id: movie.id)
                async let creditsTask = tmdbService.getMovieCredits(id: movie.id)
                async let videosTask = tmdbService.getMovieVideos(id: movie.id)
                async let providersTask = tmdbService.getMovieWatchProviders(id: movie.id)
                async let similarTask = tmdbService.getSimilarMovies(id: movie.id, page: 1)
                async let externalIdsTask = tmdbService.getMovieExternalIds(id: movie.id)

                let (details, credits, videos, providers, similar, externalIds) = try await (
                    detailsTask, creditsTask, videosTask, providersTask, similarTask, externalIdsTask
                )

                // Get current country for watch providers
                let country = LocalizationManager.shared.currentCountry.id
                let watchProviders = providers.results[country]

                // Cache the details
                try await detailCache.cacheMovieDetails(
                    movie: details,
                    credits: credits,
                    videos: videos.results.filter { $0.type == "Trailer" && $0.site == "YouTube" },
                    watchProviders: watchProviders,
                    similarMovies: Array(similar.results.prefix(10)),
                    imdbId: externalIds.imdbId
                )

                cached += 1

                // Prefetch all images for offline viewing using correct URLs
                var imageURLs: [String] = []

                // 1. Poster (w500)
                if let posterPath = details.posterPath {
                    imageURLs.append("\(tmdbPosterBaseURL)\(posterPath)")
                }

                // 2. Backdrop (w1280)
                if let backdropPath = details.backdropPath {
                    imageURLs.append("\(tmdbBackdropBaseURL)\(backdropPath)")
                }

                // 3. Cast profile images (w185) - top 10
                for member in credits.cast.prefix(10) {
                    if let profilePath = member.profilePath {
                        imageURLs.append("\(tmdbProfileBaseURL)\(profilePath)")
                    }
                }

                // 4. Watch provider logos (original)
                if let providers = watchProviders {
                    let allProviders = (providers.flatrate ?? []) + (providers.rent ?? []) + (providers.buy ?? [])
                    let uniqueProviders = Array(Set(allProviders.map { $0.logoPath }))
                    for logoPath in uniqueProviders {
                        imageURLs.append("\(tmdbLogoBaseURL)\(logoPath)")
                    }
                }

                // 5. Similar movies posters (w500) - top 10
                let filteredVideos = videos.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
                for similarMovie in similar.results.prefix(10) {
                    if let posterPath = similarMovie.posterPath {
                        imageURLs.append("\(tmdbPosterBaseURL)\(posterPath)")
                    }
                }

                // 6. YouTube trailer thumbnails
                for video in filteredVideos {
                    imageURLs.append("https://img.youtube.com/vi/\(video.key)/hqdefault.jpg")
                }

                if !imageURLs.isEmpty {
                    await imageCache.prefetchImages(imageURLs, onWiFiOnly: false)
                }

                // Update progress
                let progress = progressStart + (Double(index + 1) / Double(totalMovies)) * (progressEnd - progressStart)
                prefetchProgress = progress

                Logger.debug("[DailyPrefetch] Cached movie \(cached)/\(totalMovies): \(movie.title) + \(imageURLs.count) images")

                // Small delay to respect rate limits
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s

            } catch {
                Logger.warning("[DailyPrefetch] Failed to cache movie \(movie.title): \(error.localizedDescription)")
            }
        }
    }

    private func cacheTVShowDetails(_ tvShows: [TVShow], progressStart: Double = 0, progressEnd: Double = 1) async {
        let totalShows = tvShows.count
        guard totalShows > 0 else { return }

        var cached = 0

        for (index, tvShow) in tvShows.enumerated() {
            do {
                // Fetch full details
                async let detailsTask = tmdbService.getTVShowDetails(id: tvShow.id)
                async let creditsTask = tmdbService.getTVShowCredits(id: tvShow.id)
                async let videosTask = tmdbService.getTVShowVideos(id: tvShow.id)
                async let providersTask = tmdbService.getTVShowWatchProviders(id: tvShow.id)
                async let similarTask = tmdbService.getSimilarTVShows(id: tvShow.id, page: 1)
                async let externalIdsTask = tmdbService.getTVShowExternalIds(id: tvShow.id)

                let (details, credits, videos, providers, similar, externalIds) = try await (
                    detailsTask, creditsTask, videosTask, providersTask, similarTask, externalIdsTask
                )

                // Get current country for watch providers
                let country = LocalizationManager.shared.currentCountry.id
                let watchProviders = providers.results[country]

                // Cache the details
                try await detailCache.cacheTVShowDetails(
                    tvShow: details,
                    credits: credits,
                    videos: videos.results.filter { $0.type == "Trailer" && $0.site == "YouTube" },
                    watchProviders: watchProviders,
                    similarShows: Array(similar.results.prefix(10)),
                    imdbId: externalIds.imdbId
                )

                cached += 1

                // Prefetch all images for offline viewing using correct URLs
                var imageURLs: [String] = []

                // 1. Poster (w500)
                if let posterPath = details.posterPath {
                    imageURLs.append("\(tmdbPosterBaseURL)\(posterPath)")
                }

                // 2. Backdrop (w1280)
                if let backdropPath = details.backdropPath {
                    imageURLs.append("\(tmdbBackdropBaseURL)\(backdropPath)")
                }

                // 3. Cast profile images (w185) - top 10
                for member in credits.cast.prefix(10) {
                    if let profilePath = member.profilePath {
                        imageURLs.append("\(tmdbProfileBaseURL)\(profilePath)")
                    }
                }

                // 4. Watch provider logos (original)
                if let providers = watchProviders {
                    let allProviders = (providers.flatrate ?? []) + (providers.rent ?? []) + (providers.buy ?? [])
                    let uniqueProviders = Array(Set(allProviders.map { $0.logoPath }))
                    for logoPath in uniqueProviders {
                        imageURLs.append("\(tmdbLogoBaseURL)\(logoPath)")
                    }
                }

                // 5. Similar TV shows posters (w500) - top 10
                let filteredVideos = videos.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
                for similarShow in similar.results.prefix(10) {
                    if let posterPath = similarShow.posterPath {
                        imageURLs.append("\(tmdbPosterBaseURL)\(posterPath)")
                    }
                }

                // 6. YouTube trailer thumbnails
                for video in filteredVideos {
                    imageURLs.append("https://img.youtube.com/vi/\(video.key)/hqdefault.jpg")
                }

                if !imageURLs.isEmpty {
                    await imageCache.prefetchImages(imageURLs, onWiFiOnly: false)
                }

                // Update progress
                let progress = progressStart + (Double(index + 1) / Double(totalShows)) * (progressEnd - progressStart)
                prefetchProgress = progress

                Logger.debug("[DailyPrefetch] Cached TV show \(cached)/\(totalShows): \(tvShow.name) + \(imageURLs.count) images")

                // Small delay to respect rate limits
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s

            } catch {
                Logger.warning("[DailyPrefetch] Failed to cache TV show \(tvShow.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cleanup

    /// Delete all prefetched content (for testing or settings)
    func clearPrefetchedContent() async {
        do {
            try await detailCache.clearAllCache()
            lastPrefetchDate = nil
            userDefaults.removeObject(forKey: lastPrefetchKey)
            Logger.debug("[DailyPrefetch] All prefetched content cleared")
        } catch {
            Logger.error("[DailyPrefetch] Failed to clear content: \(error.localizedDescription)")
        }
    }
}
