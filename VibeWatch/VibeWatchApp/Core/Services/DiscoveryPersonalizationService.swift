import Foundation

/// Service for generating personalized Discovery carousels based on user preferences
/// Implements scoring algorithms and diversity enforcement
@MainActor
class DiscoveryPersonalizationService: ObservableObject {
    static let shared = DiscoveryPersonalizationService()

    // MARK: - Dependencies

    private let tmdbService: TMDBServiceProtocol
    private let preferenceManager: UserPreferenceManager
    private let sqliteService: SQLiteService
    private let cerebrasService: CerebrasService
    
    // In-memory cache for instant access (avoids DB reads on view reloads)
    private var memoryCache: [PersonalizedCarousel]?
    
    /// Returns true if valid data is available in the memory cache
    var hasCachedData: Bool {
        return memoryCache != nil
    }

    // MARK: - Constants

    private let maxItemsPerCarousel = 20
    private let minDiversityThreshold = 3 // Min different genres per carousel
    private let maxItemsPerGenre = 5 // Max items from same genre
    private let maxDynamicLoglineItems = 40

    // MARK: - Initialization

    private init(
        tmdbService: TMDBServiceProtocol = TMDBService.shared,
        preferenceManager: UserPreferenceManager = .shared,
        sqliteService: SQLiteService = .shared,
        cerebrasService: CerebrasService = .shared
    ) {
        self.tmdbService = tmdbService
        self.preferenceManager = preferenceManager
        self.sqliteService = sqliteService
        self.cerebrasService = cerebrasService

        Logger.info("[DiscoveryPersonalizationService] Initialized")
    }

    // MARK: - Public Methods

    /// Generate 5-6 personalized carousels for the user
    /// Uses cache-first strategy for instant loading
    func generatePersonalizedCarousels(
        userProfile: UserProfile,
        filters: GlobalDiscoveryFilters? = nil,
        forceRefresh: Bool = false
    ) async throws -> [PersonalizedCarousel] {

        // LEVEL 1: MEMORY CACHE (Instant)
        if !forceRefresh, let cached = memoryCache {
            Logger.info("[DiscoveryPersonalizationService] ✅ Loaded from memory cache (instant)")
            return cached
        }

        // LEVEL 2: DATABASE CACHE (Fast)
        if !forceRefresh {
            if let cached = try await loadFromCache(userId: userProfile.userId) {
                Logger.info("[DiscoveryPersonalizationService] ✅ Loaded \(cached.count) carousels from DB cache")
                self.memoryCache = cached
                return cached
            }
            Logger.info("[DiscoveryPersonalizationService] ⚠️ Cache miss or expired - fetching from API")
        } else {
            Logger.info("[DiscoveryPersonalizationService] 🔄 Force refresh requested - fetching from API")
        }

        // LEVEL 3: API GENERATION (Slow)
        var carousels: [PersonalizedCarousel] = []
        var seenMovieIds: Set<Int> = [] // Track to prevent duplicates

        Logger.info("[DiscoveryPersonalizationService] Generating carousels for user: \(userProfile.userId)")

        // Core Carousel 1: Daily Mix
        let dailyMix = try await generateDailyMix(userProfile: userProfile, filters: filters, excluding: seenMovieIds)
        carousels.append(dailyMix)
        seenMovieIds.formUnion(Set(dailyMix.items.map(\.id)))
        Logger.debug("[DiscoveryPersonalizationService] ✅ Generated Daily Mix with \(dailyMix.items.count) items")

        // Core Carousel 2: Trending in Top Genre (with deduplication)
        if let topGenre = userProfile.topGenres.first {
            let trendingGenre = try await generateTrendingInGenre(genre: topGenre, userProfile: userProfile, filters: filters, excluding: seenMovieIds)
            carousels.append(trendingGenre)
            seenMovieIds.formUnion(Set(trendingGenre.items.map(\.id)))
            Logger.debug("[DiscoveryPersonalizationService] ✅ Generated Trending Genre with \(trendingGenre.items.count) items")
        } else {
            let hotThisWeek = try await generateHotThisWeek(filters: filters, excluding: seenMovieIds)
            carousels.append(hotThisWeek)
            seenMovieIds.formUnion(Set(hotThisWeek.items.map(\.id)))
            Logger.debug("[DiscoveryPersonalizationService] ✅ Generated Hot This Week with \(hotThisWeek.items.count) items")
        }

        // Core Carousel 3: Because You Liked (with deduplication)
        if let likedMedia = userProfile.recentActivity.likedMedia.first {
            let similarContent = try await generateSimilarContent(to: likedMedia, userProfile: userProfile, excluding: seenMovieIds)
            carousels.append(similarContent)
            seenMovieIds.formUnion(Set(similarContent.items.map(\.id)))
            Logger.debug("[DiscoveryPersonalizationService] ✅ Generated Similar Content with \(similarContent.items.count) items")
        } else {
            let awardWinners = try await generateAwardWinners(filters: filters, excluding: seenMovieIds)
            carousels.append(awardWinners)
            seenMovieIds.formUnion(Set(awardWinners.items.map(\.id)))
            Logger.debug("[DiscoveryPersonalizationService] ✅ Generated Award Winners with \(awardWinners.items.count) items")
        }

        // Rotating Carousels (2-3) with deduplication
        Logger.debug("[DiscoveryPersonalizationService] Selecting rotating carousels (excluding \(seenMovieIds.count) movies)...")
        let rotatingCarousels = try await selectRotatingCarousels(
            userProfile: userProfile,
            filters: filters,
            excludingTypes: Set(carousels.map(\.type)),
            excludingMovies: seenMovieIds
        )
        Logger.debug("[DiscoveryPersonalizationService] ✅ Generated \(rotatingCarousels.count) rotating carousels")
        carousels.append(contentsOf: rotatingCarousels)
        for carousel in rotatingCarousels {
            seenMovieIds.formUnion(Set(carousel.items.map(\.id)))
        }

        // Ensure a stable minimum for new users (fallbacks) with deduplication
        let minimumCarousels = 5
        var usedTypes = Set(carousels.map(\.type))
        if carousels.count < minimumCarousels {
            Logger.debug("[DiscoveryPersonalizationService] Only \(carousels.count) carousels - adding fallbacks to reach minimum \(minimumCarousels)")
        }
        while carousels.count < minimumCarousels {
            if !usedTypes.contains(.hotThisWeek),
               let carousel = try? await generateHotThisWeek(filters: filters, excluding: seenMovieIds) {
                carousels.append(carousel)
                usedTypes.insert(carousel.type)
                seenMovieIds.formUnion(Set(carousel.items.map(\.id)))
                Logger.debug("[DiscoveryPersonalizationService] ✅ Added fallback: Hot This Week with \(carousel.items.count) items")
                continue
            }
            if !usedTypes.contains(.awardWinners),
               let carousel = try? await generateAwardWinners(filters: filters, excluding: seenMovieIds) {
                carousels.append(carousel)
                usedTypes.insert(carousel.type)
                seenMovieIds.formUnion(Set(carousel.items.map(\.id)))
                Logger.debug("[DiscoveryPersonalizationService] ✅ Added fallback: Award Winners with \(carousel.items.count) items")
                continue
            }
            if !usedTypes.contains(.staffPicks),
               let carousel = try? await generateStaffPicks(userProfile: userProfile, filters: filters, excluding: seenMovieIds) {
                carousels.append(carousel)
                usedTypes.insert(carousel.type)
                seenMovieIds.formUnion(Set(carousel.items.map(\.id)))
                Logger.debug("[DiscoveryPersonalizationService] ✅ Added fallback: Staff Picks with \(carousel.items.count) items")
                continue
            }
            Logger.warning("[DiscoveryPersonalizationService] Could not reach minimum carousels - stopping at \(carousels.count)")
            break
        }

        carousels = await applyDynamicLoglines(to: carousels, userProfile: userProfile)

        // Cache to database for offline access
        await cachePersonalizedContent(carousels: carousels, userId: userProfile.userId)
        
        // Update memory cache
        self.memoryCache = carousels

        Logger.info("[DiscoveryPersonalizationService] Generated \(carousels.count) carousels")

        return carousels
    }
    
    /// Clear in-memory cache (call on sign out)
    func clearMemoryCache() {
        memoryCache = nil
        Logger.info("[DiscoveryPersonalizationService] Memory cache cleared")
    }

    /// Warm the in-memory cache from the DB cache when available.
    func loadCachedCarouselsIfAvailable(userId: String?) async -> [PersonalizedCarousel]? {
        do {
            if let userId, !userId.isEmpty,
               let cached = try await loadFromCache(userId: userId) {
                memoryCache = cached
                return cached
            }

            let deviceId = await sqliteService.getOrCreateDeviceId()
            if let cached = try await loadFromCache(deviceId: deviceId) {
                memoryCache = cached
                return cached
            }
        } catch {
            Logger.warning("[DiscoveryPersonalizationService] Failed to load cache: \(error.localizedDescription)")
        }
        return nil
    }

    /// Calculate personalization score for a movie/show
    func calculatePersonalizationScore(
        movie: Movie,
        userProfile: UserProfile
    ) -> Double {
        var score = 0.0

        // Genre match (0-50 points)
        let genreMatches = movie.genreIds?.filter { genreId in
            userProfile.topGenres.contains { $0.genreId == genreId }
        } ?? []
        score += Double(genreMatches.count) * 15.0

        // Genre preference strength (0-30 points)
        for genreId in movie.genreIds ?? [] {
            if let preference = userProfile.topGenres.first(where: { $0.genreId == genreId }) {
                score += preference.totalScore * 2.0
            }
        }

        // Quality score (0-20 points)
        score += movie.voteAverage * 2.0

        // Popularity factor (0-10 points)
        score += min(movie.popularity / 100.0, 10.0)

        // Recency bias (0-15 points) - prefer newer content
        if let releaseDate = movie.releaseDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: releaseDate) {
                let year = Calendar.current.component(.year, from: date)
                if year >= 2020 {
                    score += Double(year - 2020) * 2.0
                }
            }
        }

        // Diversity randomness (0-5 points)
        score += Double.random(in: 0...5)

        return score
    }

    /// Ensure diversity in recommendations to prevent filter bubble
    func ensureDiversity<T: MovieProtocol>(
        _ items: [ScoredItem<T>],
        maxPerGenre: Int = 5
    ) -> [ScoredItem<T>] {
        var result: [ScoredItem<T>] = []
        var genreCounts: [Int: Int] = [:]

        for item in items {
            let genres = item.item.genreIds ?? []

            // Check if adding this item would exceed genre limit
            var canAdd = true
            for genre in genres {
                if genreCounts[genre, default: 0] >= maxPerGenre {
                    canAdd = false
                    break
                }
            }

            if canAdd {
                result.append(item)
                for genre in genres {
                    genreCounts[genre, default: 0] += 1
                }
            }

            if result.count >= maxItemsPerCarousel {
                break
            }
        }

        return result
    }

    // MARK: - Private Methods - Carousel Generators

    private func generateDailyMix(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Daily Mix (excluding \(excluding.count) movies)")

        let rawCandidates: [Movie]
        if let filters, filters.isActive {
            let topGenreIds = Array(userProfile.topGenres.prefix(3).map { $0.genreId })
            rawCandidates = try await fetchDiscoveredContent(topGenreIds: topGenreIds, filters: filters, page: 1)
        } else {
            async let trendingResponse = tmdbService.getTrendingMovies(timeWindow: .day, page: 1)
            async let topRatedResponse = tmdbService.getTopRatedMovies(page: 1)
            async let popularResponse = tmdbService.getPopularMovies(page: 1)

            let (trending, topRated, popular) = try await (trendingResponse, topRatedResponse, popularResponse)
            rawCandidates = trending.results + topRated.results + popular.results
        }

        // DEDUPLICATION: Filter out movies already shown in other carousels
        let allCandidates = deduplicateMoviesById(rawCandidates).filter { !excluding.contains($0.id) }

        // Score each candidate
        let scored = allCandidates.map { movie in
            ScoredItem(
                item: movie,
                score: calculatePersonalizationScore(movie: movie, userProfile: userProfile)
            )
        }

        // Sort by score and ensure diversity
        let sortedScored = scored.sorted { $0.score > $1.score }
        let diverseItems = ensureDiversity(sortedScored, maxPerGenre: maxItemsPerGenre)
        let top20 = Array(diverseItems.prefix(maxItemsPerCarousel))

        return PersonalizedCarousel(
            type: .dailyMix,
            title: "carousel.dailyMix".localized,
            items: top20.map { $0.item },
            descriptions: [:],
            reason: "Personalized picks based on your taste"
        )
    }

    private func generateTrendingInGenre(genre: GenrePreference, userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Trending in \(genre.genreName) (excluding \(excluding.count) movies)")

        let rawFiltered: [Movie]
        if let filters, filters.isActive {
            rawFiltered = try await fetchDiscoveredContent(
                topGenreIds: [genre.genreId],
                filters: filters,
                page: 1
            )
        } else {
            // Fetch trending movies
            let trending = try await tmdbService.getTrendingMovies(timeWindow: .week, page: 1)

            // Filter by genre
            rawFiltered = trending.results.filter { movie in
                movie.genreIds?.contains(genre.genreId) ?? false
            }
        }

        // DEDUPLICATION: Filter out movies already shown
        let filtered = rawFiltered.filter { !excluding.contains($0.id) }

        // Score and sort
        let scored = filtered.map { movie in
            ScoredItem(
                item: movie,
                score: calculatePersonalizationScore(movie: movie, userProfile: userProfile)
            )
        }
        .sorted { $0.score > $1.score }

        let top20 = Array(scored.prefix(maxItemsPerCarousel))

        return PersonalizedCarousel(
            type: .trendingGenre,
            title: String(format: "carousel.trendingInGenre".localized, genre.genreName),
            items: top20.map { $0.item },
            descriptions: [:],
            reason: "Popular \(genre.genreName) content right now"
        )
    }

    private func generateSimilarContent(to media: MediaSummary, userProfile: UserProfile, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating similar to \(media.title) (excluding \(excluding.count) movies)")

        // Fetch similar movies from TMDB
        let similar = try await tmdbService.getSimilarMovies(id: media.id, page: 1)

        // DEDUPLICATION: Filter out movies already shown
        let filteredSimilar = similar.results.filter { !excluding.contains($0.id) }

        let reranked = await rerankSimilarMovies(seedMovieId: media.id, candidates: filteredSimilar)

        // Score based on user preferences
        let scored = reranked.map { movie in
            ScoredItem(
                item: movie,
                score: calculatePersonalizationScore(movie: movie, userProfile: userProfile)
            )
        }
        .sorted { $0.score > $1.score }

        let top20 = Array(scored.prefix(maxItemsPerCarousel))

        return PersonalizedCarousel(
            type: .becauseYouLiked,
            title: String(format: "carousel.becauseYouLiked".localized, media.title),
            items: top20.map { $0.item },
            descriptions: [:],
            reason: "Similar to movies you enjoyed"
        )
    }

    private func generateHiddenGems(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Hidden Gems (excluding \(excluding.count) movies)")

        let topGenreIds = userProfile.topGenres.prefix(3).map { $0.genreId }
        var allHiddenGems: [Movie] = []
        let minItems = 10 // Minimum items per carousel

        // Fetch multiple pages if needed to get enough unique hidden gems
        for page in 1...5 { // More pages since filtering is strict
            let rawCandidates: [Movie]
            if let filters, filters.isActive {
                rawCandidates = try await fetchDiscoveredContent(
                    topGenreIds: Array(topGenreIds),
                    filters: filters,
                    page: page,
                    forceSortBy: .ratingDesc,
                    minRatingOverride: 7.5
                )
            } else {
                // Fetch top rated movies (which includes hidden gems)
                let topRated = try await tmdbService.getTopRatedMovies(page: page)
                rawCandidates = topRated.results
            }

            // DEDUPLICATION: Filter out movies already shown
            let candidates = rawCandidates.filter { movie in
                !excluding.contains(movie.id) && !allHiddenGems.contains(where: { $0.id == movie.id })
            }

            // Filter for high rating but lower popularity
            let hiddenGems = candidates.filter { movie in
                movie.voteAverage >= 7.5 && movie.popularity < 50
            }

            // Filter by preferred genres
            let filtered = hiddenGems.filter { movie in
                guard !topGenreIds.isEmpty else { return true }
                return movie.genreIds?.contains(where: { topGenreIds.contains($0) }) ?? false
            }

            allHiddenGems.append(contentsOf: filtered)

            if allHiddenGems.count >= maxItemsPerCarousel {
                break
            }
        }

        guard allHiddenGems.count >= minItems else {
            throw NSError(domain: "DiscoveryPersonalizationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough unique items for Hidden Gems carousel"])
        }

        // Score and sort
        let scored = allHiddenGems
            .map { movie in
                ScoredItem(
                    item: movie,
                    score: calculatePersonalizationScore(movie: movie, userProfile: userProfile)
                )
            }
            .sorted { $0.score > $1.score }

        let top20 = Array(scored.prefix(maxItemsPerCarousel))

        let genreName = userProfile.topGenres.first?.genreName ?? "Your Favorites"

        return PersonalizedCarousel(
            type: .hiddenGems,
            title: String(format: "carousel.hiddenGems".localized, genreName),
            items: top20.map { $0.item },
            descriptions: [:],
            reason: "Underrated movies you'll love"
        )
    }

    private func generateContinueJourney(userProfile: UserProfile, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Continue Journey (excluding \(excluding.count) movies)")

        let watchlist = userProfile.recentActivity.watchlist

        // DEDUPLICATION: Filter out movies already shown
        let filteredWatchlist = watchlist.filter { !excluding.contains($0.id) }

        // Convert to Movie objects (fetch from cache or TMDB)
        var movies: [Movie] = []
        for item in filteredWatchlist.prefix(maxItemsPerCarousel) {
            if let movie = try? await tmdbService.getMovieDetails(id: item.id) {
                movies.append(movie)
            }
        }

        return PersonalizedCarousel(
            type: .continueJourney,
            title: "carousel.continueJourney".localized,
            items: movies,
            descriptions: [:],
            reason: "From your watchlist"
        )
    }

    private func generateFromSearches(userProfile: UserProfile, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating From Your Searches (excluding \(excluding.count) movies)")

        guard let lastSearch = userProfile.recentActivity.lastSearchQuery else {
            throw PersonalizationError.insufficientData
        }

        // Search based on last query
        let results = try await tmdbService.searchMovies(query: lastSearch, page: 1)

        // DEDUPLICATION: Filter out movies already shown
        let filteredResults = results.results.filter { !excluding.contains($0.id) }

        // Score results
        let scored = filteredResults.map { movie in
            ScoredItem(
                item: movie,
                score: calculatePersonalizationScore(movie: movie, userProfile: userProfile)
            )
        }
        .sorted { $0.score > $1.score }

        let top20 = Array(scored.prefix(maxItemsPerCarousel))

        return PersonalizedCarousel(
            type: .fromSearches,
            title: "carousel.fromSearches".localized,
            items: top20.map { $0.item },
            descriptions: [:],
            reason: "Based on your recent searches"
        )
    }

    private func generateTopTVPicks(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Top TV Picks (excluding \(excluding.count) movies)")

        let topGenreIds = userProfile.topGenres.prefix(3).map { $0.genreId }

        let rawFiltered: [Movie]
        if let filters, filters.isActive {
            rawFiltered = try await fetchDiscoveredTVContent(
                topGenreIds: Array(topGenreIds),
                filters: filters,
                page: 1
            )
        } else {
            // Fetch popular TV shows
            let tvShows = try await tmdbService.getPopularTVShows(page: 1)

            // Filter by preferred genres and convert to Movie for compatibility
            rawFiltered = tvShows.results
                .filter { show in
                    show.genreIds?.contains(where: { topGenreIds.contains($0) }) ?? false
                }
                .map(mapTVShowToMovie)
        }

        // DEDUPLICATION: Filter out movies already shown
        let filtered = rawFiltered.filter { !excluding.contains($0.id) }

        let top20 = Array(filtered.prefix(maxItemsPerCarousel))

        return PersonalizedCarousel(
            type: .topTVPicks,
            title: "carousel.topTVPicks".localized,
            items: top20,
            descriptions: [:],
            reason: "TV shows matching your taste"
        )
    }

    private func generateStaffPicks(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Staff Picks (excluding \(excluding.count) movies)")

        let topGenreIds = userProfile.topGenres.prefix(3).map { $0.genreId }
        var allCandidates: [Movie] = []
        let minItems = 10 // Minimum items per carousel

        // Fetch multiple pages if needed to get enough unique items
        for page in 1...3 {
            let rawCandidates: [Movie]
            if let filters, filters.isActive {
                rawCandidates = try await fetchDiscoveredContent(
                    topGenreIds: Array(topGenreIds),
                    filters: filters,
                    page: page,
                    forceSortBy: .ratingDesc
                )
            } else {
                // Fetch top rated movies (our "staff picks")
                let topRated = try await tmdbService.getTopRatedMovies(page: page)
                rawCandidates = topRated.results
            }

            // DEDUPLICATION: Filter out movies already shown
            let deduplicated = rawCandidates.filter { movie in
                !excluding.contains(movie.id) && !allCandidates.contains(where: { $0.id == movie.id })
            }

            // Filter by user's preferred genres
            let filtered = deduplicated.filter { movie in
                guard !topGenreIds.isEmpty else { return true }
                return movie.genreIds?.contains(where: { topGenreIds.contains($0) }) ?? false
            }

            allCandidates.append(contentsOf: filtered)

            if allCandidates.count >= maxItemsPerCarousel {
                break
            }
        }

        guard allCandidates.count >= minItems else {
            throw NSError(domain: "DiscoveryPersonalizationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough unique items for Staff Picks carousel"])
        }

        let top20 = Array(allCandidates.prefix(maxItemsPerCarousel))

        let genreName = userProfile.topGenres.first?.genreName ?? "Your Favorites"

        return PersonalizedCarousel(
            type: .staffPicks,
            title: String(format: "carousel.staffPicks".localized, genreName),
            items: top20,
            descriptions: [:],
            reason: "Curated classics and modern masterpieces"
        )
    }

    // MARK: - Private Methods - Carousel Selection

    private func selectRotatingCarousels(
        userProfile: UserProfile,
        filters: GlobalDiscoveryFilters?,
        excludingTypes excludedTypes: Set<CarouselType> = [],
        excludingMovies excludedMovies: Set<Int> = []
    ) async throws -> [PersonalizedCarousel] {
        var candidates: [CarouselCandidate] = []

        if !excludedTypes.contains(.hotThisWeek) {
            candidates.append(CarouselCandidate(
                type: .hotThisWeek,
                relevance: 85.0,
                generator: { try await self.generateHotThisWeek(filters: filters, excluding: excludedMovies) }
            ))
        }

        if !excludedTypes.contains(.awardWinners) {
            candidates.append(CarouselCandidate(
                type: .awardWinners,
                relevance: 80.0,
                generator: { try await self.generateAwardWinners(filters: filters, excluding: excludedMovies) }
            ))
        }

        // Hidden Gems (always available)
        if !excludedTypes.contains(.hiddenGems) {
            candidates.append(CarouselCandidate(
                type: .hiddenGems,
                relevance: 70.0,
                generator: { try await self.generateHiddenGems(userProfile: userProfile, filters: filters, excluding: excludedMovies) }
            ))
        }

        // Continue Journey (if watchlist >= 3)
        if userProfile.recentActivity.watchlist.count >= 3 {
            if !excludedTypes.contains(.continueJourney) {
                candidates.append(CarouselCandidate(
                    type: .continueJourney,
                    relevance: 90.0,
                    generator: { try await self.generateContinueJourney(userProfile: userProfile, excluding: excludedMovies) }
                ))
            }
        }

        // From Your Searches (if search history exists)
        if userProfile.recentActivity.lastSearchQuery != nil {
            if !excludedTypes.contains(.fromSearches) {
                candidates.append(CarouselCandidate(
                    type: .fromSearches,
                    relevance: 80.0,
                    generator: { try await self.generateFromSearches(userProfile: userProfile, excluding: excludedMovies) }
                ))
            }
        }

        // TV Picks (if TV preference > 0.5)
        if userProfile.contentTypePreference.tvRatio > 0.5 {
            if !excludedTypes.contains(.topTVPicks) {
                candidates.append(CarouselCandidate(
                    type: .topTVPicks,
                    relevance: 75.0,
                    generator: { try await self.generateTopTVPicks(userProfile: userProfile, filters: filters, excluding: excludedMovies) }
                ))
            }
        }

        // Weekend boost for Staff Picks
        if Calendar.current.isDateInWeekend(Date()) {
            if !excludedTypes.contains(.staffPicks) {
                candidates.append(CarouselCandidate(
                    type: .staffPicks,
                    relevance: 85.0,
                    generator: { try await self.generateStaffPicks(userProfile: userProfile, filters: filters, excluding: excludedMovies) }
                ))
            }
        }

        // Sort by relevance and take top 2-3
        let selected = candidates
            .sorted { $0.relevance > $1.relevance }
            .prefix(3)

        var carousels: [PersonalizedCarousel] = []
        for candidate in selected {
            do {
                let carousel = try await candidate.generator()
                carousels.append(carousel)
            } catch {
                Logger.warning("[DiscoveryPersonalizationService] Failed to generate \(candidate.type): \(error.localizedDescription)")
            }
        }

        return carousels
    }

    // MARK: - Private Methods - Fallback Carousels

    private func generateHotThisWeek(filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Hot This Week (excluding \(excluding.count) movies)")

        var allCandidates: [Movie] = []
        let minItems = 10 // Minimum items per carousel

        // Fetch multiple pages if needed to get enough unique items
        for page in 1...3 {
            let rawCandidates: [Movie]
            if let filters, filters.isActive {
                rawCandidates = try await fetchDiscoveredContent(topGenreIds: [], filters: filters, page: page)
            } else {
                let trending = try await tmdbService.getTrendingMovies(timeWindow: .week, page: page)
                rawCandidates = trending.results
            }

            // DEDUPLICATION: Filter out movies already shown
            let newCandidates = rawCandidates.filter { movie in
                !excluding.contains(movie.id) && !allCandidates.contains(where: { $0.id == movie.id })
            }
            allCandidates.append(contentsOf: newCandidates)

            if allCandidates.count >= maxItemsPerCarousel {
                break
            }
        }

        guard allCandidates.count >= minItems else {
            throw NSError(domain: "DiscoveryPersonalizationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough unique items for Hot This Week carousel"])
        }

        let top20 = Array(allCandidates.prefix(maxItemsPerCarousel))

        return PersonalizedCarousel(
            type: .hotThisWeek,
            title: "carousel.hotThisWeek".localized,
            items: top20,
            descriptions: [:],
            reason: "Trending this week"
        )
    }

    private func generateAwardWinners(filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Award Winners (excluding \(excluding.count) movies)")

        var allCandidates: [Movie] = []
        let minItems = 10 // Minimum items per carousel

        // Fetch multiple pages if needed to get enough unique items
        for page in 1...3 {
            let rawCandidates: [Movie]
            if let filters, filters.isActive {
                rawCandidates = try await fetchDiscoveredContent(topGenreIds: [], filters: filters, page: page, forceSortBy: .ratingDesc)
            } else {
                let topRated = try await tmdbService.getTopRatedMovies(page: page)
                rawCandidates = topRated.results
            }

            // DEDUPLICATION: Filter out movies already shown
            let newCandidates = rawCandidates.filter { movie in
                !excluding.contains(movie.id) && !allCandidates.contains(where: { $0.id == movie.id })
            }
            allCandidates.append(contentsOf: newCandidates)

            if allCandidates.count >= maxItemsPerCarousel {
                break
            }
        }

        guard allCandidates.count >= minItems else {
            throw NSError(domain: "DiscoveryPersonalizationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough unique items for Award Winners carousel"])
        }

        let top20 = Array(allCandidates.prefix(maxItemsPerCarousel))

        return PersonalizedCarousel(
            type: .awardWinners,
            title: "carousel.awardWinners".localized,
            items: top20,
            descriptions: [:],
            reason: "Critically acclaimed favorites"
        )
    }

    // MARK: - Private Methods - Filtered Fetching

    private func fetchDiscoveredContent(
        topGenreIds: [Int],
        filters: GlobalDiscoveryFilters,
        page: Int,
        forceSortBy: DiscoverySortOption? = nil,
        minRatingOverride: Double? = nil
    ) async throws -> [Movie] {
        let sortBy = (forceSortBy ?? filters.sortBy).tmdbValue(for: .movie)

        let runtime = filters.getRuntimeRange()
        let rating = filters.getRatingRange()
        let (releaseDateGte, releaseDateLte) = yearDateRange(filters: filters)

        let effectiveMinRating = max(rating.min ?? 0.0, minRatingOverride ?? 0.0)
        let minRating: Double? = (effectiveMinRating > 0) ? effectiveMinRating : nil
        let maxRating: Double? = rating.max

        let genreIds = topGenreIds.isEmpty ? [nil] : topGenreIds.map { Optional($0) }
        let countries = filters.countries.isEmpty ? [nil] : Array(filters.countries.prefix(3)).map { Optional($0) }

        var results: [Movie] = []
        var seen: Set<Int> = []

        for country in countries {
            for genreId in genreIds {
                let response = try await tmdbService.discoverMovies(
                    withGenre: genreId,
                    sortBy: sortBy,
                    page: page,
                    minRuntime: runtime.min,
                    maxRuntime: runtime.max,
                    minRating: minRating,
                    maxRating: maxRating,
                    releaseDateGte: releaseDateGte,
                    releaseDateLte: releaseDateLte,
                    country: country
                )

                for movie in response.results {
                    if seen.insert(movie.id).inserted {
                        results.append(movie)
                    }
                    if results.count >= maxItemsPerCarousel * 3 {
                        return results
                    }
                }
            }
        }

        return results
    }

    private func fetchDiscoveredTVContent(
        topGenreIds: [Int],
        filters: GlobalDiscoveryFilters,
        page: Int,
        forceSortBy: DiscoverySortOption? = nil,
        minRatingOverride: Double? = nil
    ) async throws -> [Movie] {
        let sortBy = (forceSortBy ?? filters.sortBy).tmdbValue(for: .tv)

        let rating = filters.getRatingRange()
        let (firstAirDateGte, firstAirDateLte) = yearDateRange(filters: filters)

        let effectiveMinRating = max(rating.min ?? 0.0, minRatingOverride ?? 0.0)
        let minRating: Double? = (effectiveMinRating > 0) ? effectiveMinRating : nil
        let maxRating: Double? = rating.max

        let genreIds = topGenreIds.isEmpty ? [nil] : topGenreIds.map { Optional($0) }
        let countries = filters.countries.isEmpty ? [nil] : Array(filters.countries.prefix(3)).map { Optional($0) }

        var results: [Movie] = []
        var seen: Set<Int> = []

        for country in countries {
            for genreId in genreIds {
                let response = try await tmdbService.discoverTVShows(
                    withGenre: genreId,
                    sortBy: sortBy,
                    page: page,
                    minRating: minRating,
                    maxRating: maxRating,
                    firstAirDateGte: firstAirDateGte,
                    firstAirDateLte: firstAirDateLte,
                    country: country
                )

                for show in response.results {
                    if seen.insert(show.id).inserted {
                        results.append(mapTVShowToMovie(show))
                    }
                    if results.count >= maxItemsPerCarousel * 3 {
                        return results
                    }
                }
            }
        }

        return results
    }

    private func yearDateRange(filters: GlobalDiscoveryFilters) -> (gte: String?, lte: String?) {
        let yearRange = filters.getYearRange()
        let gte = yearRange.start.map { "\($0)-01-01" }
        let lte = yearRange.end.map { "\($0)-12-31" }
        return (gte, lte)
    }

    private func mapTVShowToMovie(_ show: TVShow) -> Movie {
        Movie(
            id: show.id,
            title: show.name,
            overview: show.overview,
            posterPath: show.posterPath,
            backdropPath: show.backdropPath,
            releaseDate: show.firstAirDate,
            voteAverage: show.voteAverage,
            voteCount: show.voteCount,
            genreIds: show.genreIds,
            genres: show.genres,
            adult: false,
            originalLanguage: show.originalLanguage,
            popularity: show.popularity,
            runtime: nil,
            status: show.status,
            tagline: show.tagline,
            productionCountries: show.productionCountries,
            imdbId: show.imdbId
        )
    }

    // MARK: - Private Methods - Embedding Similarity

    private var embeddingModelName: String { "zai-glm-4.6" }

    private func rerankSimilarMovies(seedMovieId: Int, candidates: [Movie]) async -> [Movie] {
        guard candidates.count >= 3 else { return candidates }

        guard let seed = try? await fetchMovieEmbedding(movieId: seedMovieId) else { return candidates }
        guard !seed.isEmpty else { return candidates }

        let embeddings = (try? await fetchMovieEmbeddings(movieIds: candidates.map(\.id))) ?? [:]
        if embeddings.isEmpty { return candidates }

        let scored: [(Movie, Double)] = candidates.map { movie in
            guard let vec = embeddings[movie.id] else { return (movie, -Double.infinity) }
            return (movie, cosineSimilarity(seed, vec))
        }

        let reranked = scored.sorted { $0.1 > $1.1 }.map(\.0)
        return reranked
    }

    private func fetchMovieEmbedding(movieId: Int) async throws -> [Double]? {
        let rows = try await sqliteService.queryRaw("""
            SELECT vector_json
            FROM media_embeddings
            WHERE media_type = 'movie' AND media_id = ? AND model = ?
            LIMIT 1
        """, parameters: [movieId, embeddingModelName])

        guard let json = rows.first?["vector_json"] as? String else { return nil }
        return try JSONDecoder().decode([Double].self, from: Data(json.utf8))
    }

    private func fetchMovieEmbeddings(movieIds: [Int]) async throws -> [Int: [Double]] {
        let ids = Array(Set(movieIds))
        guard !ids.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT media_id, vector_json
            FROM media_embeddings
            WHERE media_type = 'movie' AND model = ?
              AND media_id IN (\(placeholders))
        """

        let params: [Any] = [embeddingModelName] + ids
        let rows = try await sqliteService.queryRaw(sql, parameters: params)

        var result: [Int: [Double]] = [:]
        for row in rows {
            guard let mediaId = row["media_id"] as? Int,
                  let json = row["vector_json"] as? String,
                  let vec = try? JSONDecoder().decode([Double].self, from: Data(json.utf8)) else { continue }
            result[mediaId] = vec
        }
        return result
    }

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }

        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denom = (sqrt(normA) * sqrt(normB))
        if denom == 0 { return 0 }
        return dot / denom
    }

    // MARK: - Private Methods - Caching

    /// Load personalized carousels from database cache
    /// Returns nil if cache is expired or doesn't exist
    private func loadFromCache(userId: String) async throws -> [PersonalizedCarousel]? {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let nowString = isoFormatter.string(from: now)

        // Query cached carousel data that hasn't expired
        let rows = try await sqliteService.queryRaw("""
            SELECT * FROM personalized_discovery
            WHERE user_id = ? AND expires_at > ?
            ORDER BY carousel_type, position ASC
        """, parameters: [userId, nowString])

        guard !rows.isEmpty else {
            Logger.debug("[DiscoveryPersonalizationService] No cache found or cache expired")
            return nil
        }

        Logger.debug("[DiscoveryPersonalizationService] Found \(rows.count) cached items, loading movie data...")

        // Group rows by carousel_type and extract movie data
        var carouselMovies: [String: [(movie: Movie, position: Int)]] = [:]
        var carouselMetadata: [String: (title: String, reason: String)] = [:]
        var descriptions: [String: [String: String]] = [:] // carousel type -> media id -> description

        for row in rows {
            guard let typeString = row["carousel_type"] as? String,
                  let title = row["carousel_title"] as? String,
                  let position = row["position"] as? Int else {
                continue
            }

            let reason = row["reason"] as? String ?? ""
            let description = row["description"] as? String

            // Try to decode movie from cached JSON data
            var movie: Movie?
            if let movieDataString = row["media_data"] as? String,
               !movieDataString.isEmpty,
               let movieData = movieDataString.data(using: .utf8),
               let decodedMovie = try? JSONDecoder().decode(Movie.self, from: movieData) {
                movie = decodedMovie
            } else {
                // Cache is in old format without full movie data - invalidate it
                Logger.warning("[DiscoveryPersonalizationService] Cache missing movie data - will regenerate")
                return nil
            }

            guard let validMovie = movie else { continue }

            if carouselMovies[typeString] == nil {
                carouselMovies[typeString] = []
                carouselMetadata[typeString] = (title: title, reason: reason)
                descriptions[typeString] = [:]
            }

            carouselMovies[typeString]?.append((movie: validMovie, position: position))

            if let desc = description {
                descriptions[typeString]?[String(validMovie.id)] = desc
            }
        }

        Logger.debug("[DiscoveryPersonalizationService] Loaded movie data for \(carouselMovies.values.flatMap { $0 }.count) items")

        // Convert to PersonalizedCarousel objects with full movie data
        var carousels: [PersonalizedCarousel] = []
        for (typeString, movieItems) in carouselMovies {
            guard let type = CarouselType(rawValue: typeString),
                  let metadata = carouselMetadata[typeString] else {
                continue
            }

            // Sort by position and get full movie objects
            let sortedMovies = deduplicateMoviesById(movieItems
                .sorted { $0.position < $1.position }
                .map { $0.movie })

            guard !sortedMovies.isEmpty else { continue }

            let carousel = PersonalizedCarousel(
                type: type,
                title: metadata.title,
                items: sortedMovies,
                descriptions: descriptions[typeString] ?? [:],
                reason: metadata.reason
            )

            carousels.append(carousel)
        }

        Logger.info("[DiscoveryPersonalizationService] ✅ Loaded \(carousels.count) carousels from cache with full movie details")

        return carousels.isEmpty ? nil : carousels
    }

    /// Load personalized carousels from database cache using device id.
    private func loadFromCache(deviceId: String) async throws -> [PersonalizedCarousel]? {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let nowString = isoFormatter.string(from: now)

        let rows = try await sqliteService.queryRaw("""
            SELECT * FROM personalized_discovery
            WHERE device_id = ? AND expires_at > ?
            ORDER BY carousel_type, position ASC
        """, parameters: [deviceId, nowString])

        guard !rows.isEmpty else {
            Logger.debug("[DiscoveryPersonalizationService] No device cache found or cache expired")
            return nil
        }

        Logger.debug("[DiscoveryPersonalizationService] Found \(rows.count) cached items (device), loading movie data...")

        var carouselMovies: [String: [(movie: Movie, position: Int)]] = [:]
        var carouselMetadata: [String: (title: String, reason: String)] = [:]
        var descriptions: [String: [String: String]] = [:]

        for row in rows {
            guard let typeString = row["carousel_type"] as? String,
                  let title = row["carousel_title"] as? String,
                  let position = row["position"] as? Int else {
                continue
            }

            let reason = row["reason"] as? String ?? ""
            let description = row["description"] as? String

            var movie: Movie?
            if let movieDataString = row["media_data"] as? String,
               !movieDataString.isEmpty,
               let movieData = movieDataString.data(using: .utf8),
               let decodedMovie = try? JSONDecoder().decode(Movie.self, from: movieData) {
                movie = decodedMovie
            } else {
                Logger.warning("[DiscoveryPersonalizationService] Device cache missing movie data - will regenerate")
                return nil
            }

            guard let validMovie = movie else { continue }

            if carouselMovies[typeString] == nil {
                carouselMovies[typeString] = []
                carouselMetadata[typeString] = (title: title, reason: reason)
                descriptions[typeString] = [:]
            }

            carouselMovies[typeString]?.append((movie: validMovie, position: position))

            if let desc = description {
                descriptions[typeString]?[String(validMovie.id)] = desc
            }
        }

        Logger.debug("[DiscoveryPersonalizationService] Loaded movie data for \(carouselMovies.values.flatMap { $0 }.count) items (device)")

        var carousels: [PersonalizedCarousel] = []
        for (typeString, movieItems) in carouselMovies {
            guard let type = CarouselType(rawValue: typeString),
                  let metadata = carouselMetadata[typeString] else {
                continue
            }

            let sortedMovies = deduplicateMoviesById(movieItems
                .sorted { $0.position < $1.position }
                .map { $0.movie })

            guard !sortedMovies.isEmpty else { continue }

            let carousel = PersonalizedCarousel(
                type: type,
                title: metadata.title,
                items: sortedMovies,
                descriptions: descriptions[typeString] ?? [:],
                reason: metadata.reason
            )

            carousels.append(carousel)
        }

        Logger.info("[DiscoveryPersonalizationService] ✅ Loaded \(carousels.count) carousels from device cache with full movie details")

        return carousels.isEmpty ? nil : carousels
    }

    private func cachePersonalizedContent(carousels: [PersonalizedCarousel], userId: String) async {
        let deviceId = await sqliteService.getOrCreateDeviceId()
        let now = ISO8601DateFormatter().string(from: Date())
        // Expire at next local midnight so Discovery refreshes once per day.
        let nextMidnight: Date = {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date().addingTimeInterval(86400)
        }()
        let expiresAt = ISO8601DateFormatter().string(from: nextMidnight)

        // First, delete old cache for this user
        do {
            _ = try await sqliteService.delete("personalized_discovery", where: "user_id = ?", parameters: [userId], hard: true)
        } catch {
            Logger.warning("[DiscoveryPersonalizationService] Failed to clear old cache: \(error.localizedDescription)")
        }

        for carousel in carousels {
            for (index, movie) in carousel.items.enumerated() {
                let id = UUID().uuidString.lowercased()
                let description = carousel.descriptions[String(movie.id)] ?? ""

                // Encode full movie object to JSON for caching
                let movieData: String? = {
                    if let encoded = try? JSONEncoder().encode(movie),
                       let jsonString = String(data: encoded, encoding: .utf8) {
                        return jsonString
                    }
                    return nil
                }()

                let values: [String: Any] = [
                    "id": id,
                    "user_id": userId,
                    "device_id": deviceId,
                    "carousel_type": carousel.type.rawValue,
                    "carousel_title": carousel.title,
                    "media_id": movie.id,
                    "media_type": "movie",
                    "media_data": movieData ?? NSNull(),  // Store full movie JSON
                    "position": index,
                    "score": carousel.items.count - index,
                    "reason": carousel.reason,
                    "description": description,
                    "generated_at": now,
                    "expires_at": expiresAt
                ]

                do {
                    _ = try await sqliteService.insert("personalized_discovery", values: values)
                } catch {
                    Logger.error("[DiscoveryPersonalizationService] Failed to cache carousel item", error: error)
                }
            }
        }

        Logger.debug("[DiscoveryPersonalizationService] Cached \(carousels.count) carousels to database")
    }

    private func deduplicateMoviesById(_ movies: [Movie]) -> [Movie] {
        var seen: Set<Int> = []
        var result: [Movie] = []
        result.reserveCapacity(movies.count)

        for movie in movies {
            if seen.insert(movie.id).inserted {
                result.append(movie)
            }
        }
        return result
    }

    private func applyDynamicLoglines(
        to carousels: [PersonalizedCarousel],
        userProfile: UserProfile
    ) async -> [PersonalizedCarousel] {
        guard DailyQuotaManager.shared.isProUser else { return carousels }

        let uniqueMovies = collectUniqueMovies(from: carousels)
        let candidates = Array(uniqueMovies.prefix(maxDynamicLoglineItems))
        guard !candidates.isEmpty else { return carousels }

        let descriptions = try? await cerebrasService.enhanceMovieDescriptions(
            movies: candidates,
            userTone: "tailored",
            userPreferences: userProfile
        )
        guard let descriptions else { return carousels }

        return carousels.map { carousel in
            var perCarousel: [String: String] = [:]
            for movie in carousel.items {
                let key = String(movie.id)
                if let description = descriptions[key] {
                    perCarousel[key] = description
                }
            }

            let merged = carousel.descriptions.merging(perCarousel) { _, new in new }
            return PersonalizedCarousel(
                type: carousel.type,
                title: carousel.title,
                items: carousel.items,
                descriptions: merged,
                reason: carousel.reason
            )
        }
    }

    private func collectUniqueMovies(from carousels: [PersonalizedCarousel]) -> [Movie] {
        var seen = Set<Int>()
        var result: [Movie] = []
        for carousel in carousels {
            for movie in carousel.items where seen.insert(movie.id).inserted {
                result.append(movie)
            }
        }
        return result
    }
}

// MARK: - Supporting Models

struct PersonalizedCarousel {
    let type: CarouselType
    let title: String
    let items: [Movie]
    let descriptions: [String: String] // movieId -> description
    let reason: String
}

enum CarouselType: String, Codable {
    case dailyMix = "daily_mix"
    case trendingGenre = "trending_genre"
    case becauseYouLiked = "because_you_liked"
    case hiddenGems = "hidden_gems"
    case continueJourney = "continue_journey"
    case fromSearches = "from_searches"
    case topTVPicks = "top_tv_picks"
    case staffPicks = "staff_picks"
    case yearlyRewind = "yearly_rewind"
    case hotThisWeek = "hot_this_week"
    case awardWinners = "award_winners"
}

struct CarouselCandidate {
    let type: CarouselType
    let relevance: Double
    let generator: () async throws -> PersonalizedCarousel
}

struct ScoredItem<T> {
    let item: T
    let score: Double
}

// Protocol to make scoring work with both Movie and TVShow
protocol MovieProtocol {
    var id: Int { get }
    var genreIds: [Int]? { get }
    var voteAverage: Double { get }
    var popularity: Double { get }
}

extension Movie: MovieProtocol {}
extension TVShow: MovieProtocol {}

// MARK: - Errors

enum PersonalizationError: LocalizedError {
    case insufficientData
    case noResults
    case cachingFailed

    var errorDescription: String? {
        switch self {
        case .insufficientData:
            return "Insufficient user data for personalization"
        case .noResults:
            return "No results found for personalization"
        case .cachingFailed:
            return "Failed to cache personalized content"
        }
    }
}
