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
        // 4.1: la generazione caroselli passa per un budget (coalescing + tetto di concorrenza)
        // così le ~27 famiglie di carosello non producono il burst >100 richieste TMDB.
        tmdbService: TMDBServiceProtocol = BudgetedTMDBService(wrapping: TMDBService.shared),
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
    /// - Parameter onPartialResults: chiamato ogni volta che un batch è pronto, con l'elenco
    ///   completo dei caroselli disponibili fino a quel momento. Serve a togliere la generazione
    ///   dal percorso critico: misurata a freddo costa ~5 s in ~4 ondate di latenza TMDB, e senza
    ///   questo l'utente le aspetta tutte prima di vedere qualsiasi cosa. Non viene invocato sui
    ///   rami di cache (là il chiamante ha già i dati) né a generazione conclusa: l'ultima parola
    ///   resta il valore di ritorno, che è l'unico ad avere le logline dinamiche applicate.
    func generatePersonalizedCarousels(
        userProfile: UserProfile,
        filters: GlobalDiscoveryFilters? = nil,
        forceRefresh: Bool = false,
        onPartialResults: (@MainActor ([PersonalizedCarousel]) -> Void)? = nil
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
        Logger.info("[DiscoveryPersonalizationService] Generating carousels for user: \(userProfile.userId)")

        // Il costo di questa passata è il vero costo del "content loading". Contarlo è l'unico
        // modo per sapere se il collo di bottiglia è il fan-out (troppe richieste distinte) o la
        // latenza per richiesta — e quindi quale intervento abbia senso.
        let budgeted = tmdbService as? BudgetedTMDBService
        await budgeted?.resetBudgetStats()
        let generationStart = Date()

        var carousels: [PersonalizedCarousel] = []
        var usedIds: Set<Int> = [] // Daily Mix items are NOT added — hero is independent of dedup

        // Carousel 0: Daily Mix hero (always first, excluded from global dedup)
        let dailyMix = try await generateDailyMix(userProfile: userProfile, filters: filters, excluding: [])
        carousels.append(dailyMix)
        Logger.debug("[DiscoveryPersonalizationService] ✅ Daily Mix: \(dailyMix.items.count) items")

        // L'hero è pronto dopo la prima ondata di richieste: mostrarlo subito invece di tenerlo
        // in ostaggio dei batch successivi.
        onPartialResults?(carousels)
        Logger.debug("[DiscoveryPerf] parziale: hero pronto a \(String(format: "%.2f", Date().timeIntervalSince(generationStart)))s")

        // Carousels 1…N: parallel batch generation (5 at a time to respect TMDB rate limits).
        // Within each batch every generator uses the same exclusion snapshot so they run
        // concurrently. After a batch completes, priority-ordered post-hoc dedup is applied
        // and the exclusion set is updated before the next batch starts.
        let defs = buildDefinitionCatalog(userProfile: userProfile)
            .filter { $0.isEligible(userProfile) }
        let minItemsPerCarousel = 10
        let batchSize = 5

        for batchStart in stride(from: 0, to: defs.count, by: batchSize) {
            let batch = Array(defs[batchStart..<min(batchStart + batchSize, defs.count)])
            let snapshotIds = usedIds  // All generators in this batch exclude the same set

            var batchResults: [(priority: Int, carousel: PersonalizedCarousel)] = []

            await withTaskGroup(of: (Int, PersonalizedCarousel?).self) { group in
                for def in batch {
                    let priority = def.priority
                    let generate = def.generate
                    group.addTask {
                        if let c = try? await generate(userProfile, filters, snapshotIds) {
                            return (priority, c)
                        }
                        return (priority, nil)
                    }
                }
                for await (priority, result) in group {
                    if let c = result { batchResults.append((priority: priority, carousel: c)) }
                }
            }

            // Sort by priority (highest first) then apply sequential dedup across batch results
            batchResults.sort { $0.priority > $1.priority }
            for result in batchResults {
                let uniqueItems = result.carousel.items.filter { !usedIds.contains($0.id) }
                guard uniqueItems.count >= minItemsPerCarousel else {
                    Logger.debug("[DiscoveryPersonalizationService] Dropped \(result.carousel.type.rawValue) — \(uniqueItems.count) unique items after dedup")
                    continue
                }
                let deduped = PersonalizedCarousel(
                    type: result.carousel.type,
                    titleSpec: result.carousel.titleSpec,
                    items: Array(uniqueItems.prefix(maxItemsPerCarousel)),
                    descriptions: result.carousel.descriptions,
                    reason: result.carousel.reason
                )
                carousels.append(deduped)
                usedIds.formUnion(uniqueItems.map(\.id))
                Logger.debug("[DiscoveryPersonalizationService] ✅ \(deduped.type.rawValue): \(deduped.items.count) items (used: \(usedIds.count))")
            }

            // Emissione dopo ogni batch, non solo alla fine. Il dedup resta sequenziale (ogni
            // batch parte dalla snapshot aggiornata dal precedente), quindi non si paga il
            // carosello perso che costava allargare batchSize.
            onPartialResults?(carousels)
            Logger.debug("[DiscoveryPerf] parziale: \(carousels.count) caroselli a \(String(format: "%.2f", Date().timeIntervalSince(generationStart)))s")
        }

        if let stats = await budgeted?.budgetStats() {
            let elapsed = Date().timeIntervalSince(generationStart)
            Logger.info(
                "[DiscoveryPerf] cold generation: \(String(format: "%.2f", elapsed))s · "
                + "definizioni=\(defs.count) caroselli=\(carousels.count) · "
                + "chiamate TMDB=\(stats.total) (rete=\(stats.network), chiavi distinte=\(stats.distinctNetworkKeys), "
                + "coalesced=\(stats.coalesced), cache=\(stats.cacheHits))"
            )
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

    /// Butta la cache dei caroselli (memoria + DB): la prossima apertura di Scopri rigenera.
    /// Serve quando il profilo su cui i caroselli erano stati costruiti è cambiato davvero —
    /// oggi, dopo un import — non per un refresh qualsiasi: la rigenerazione costa ~100
    /// richieste TMDB e la scadenza normale resta la mezzanotte.
    func invalidateCache(userId: String?) async {
        memoryCache = nil
        do {
            if let userId, !userId.isEmpty {
                try await sqliteService.executeWrite(
                    "DELETE FROM personalized_discovery WHERE user_id = ?",
                    parameters: [userId]
                )
            }
            let deviceId = await sqliteService.getOrCreateDeviceId()
            try await sqliteService.executeWrite(
                "DELETE FROM personalized_discovery WHERE device_id = ?",
                parameters: [deviceId]
            )
            Logger.info("[DiscoveryPersonalizationService] Carousel cache invalidated")
        } catch {
            Logger.warning("[DiscoveryPersonalizationService] Cache invalidation failed: \(error.localizedDescription)")
        }
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

    /// Load stale (expired) cache as a last resort — do NOT update memoryCache so the stale data
    /// doesn't poison future in-memory reads.
    func loadStaleCachedCarouselsIfAvailable(userId: String?) async -> [PersonalizedCarousel]? {
        do {
            if let userId, !userId.isEmpty,
               let cached = try await loadFromCache(userId: userId, ignoreExpiry: true) {
                Logger.info("[DiscoveryPersonalizationService] 🔄 Serving stale cache for user")
                return cached
            }
            let deviceId = await sqliteService.getOrCreateDeviceId()
            if let cached = try await loadFromCache(deviceId: deviceId, ignoreExpiry: true) {
                Logger.info("[DiscoveryPersonalizationService] 🔄 Serving stale cache for device")
                return cached
            }
        } catch {
            Logger.warning("[DiscoveryPersonalizationService] Failed to load stale cache: \(error.localizedDescription)")
        }
        return nil
    }

    /// Load any available cache (stale or fresh) and warm the in-memory cache.
    /// Ignores expiry — staleness is determined separately via `isCacheStale(userId:)`.
    func loadAnyCachedCarouselsIfAvailable(userId: String?) async -> [PersonalizedCarousel]? {
        if let cached = memoryCache {
            return cached
        }
        do {
            if let userId, !userId.isEmpty,
               let cached = try await loadFromCache(userId: userId, ignoreExpiry: true) {
                memoryCache = cached
                return cached
            }
            let deviceId = await sqliteService.getOrCreateDeviceId()
            if let cached = try await loadFromCache(deviceId: deviceId, ignoreExpiry: true) {
                memoryCache = cached
                return cached
            }
        } catch {
            Logger.warning("[DiscoveryPersonalizationService] Failed to load any cache: \(error.localizedDescription)")
        }
        return nil
    }

    /// Returns true if the persisted cache is expired or absent.
    func isCacheStale(userId: String?) async -> Bool {
        let now = ISO8601DateFormatter().string(from: Date())
        if let userId, !userId.isEmpty,
           let rows = try? await sqliteService.queryRaw(
               "SELECT MAX(expires_at) AS max_expires FROM personalized_discovery WHERE user_id = ?",
               parameters: [userId]),
           let maxExpires = rows.first?["max_expires"] as? String {
            return maxExpires <= now
        }
        let deviceId = await sqliteService.getOrCreateDeviceId()
        if let rows = try? await sqliteService.queryRaw(
            "SELECT MAX(expires_at) AS max_expires FROM personalized_discovery WHERE device_id = ?",
            parameters: [deviceId]),
           let maxExpires = rows.first?["max_expires"] as? String {
            return maxExpires <= now
        }
        return true
    }

    /// Calculate personalization score for a movie/show
    func calculatePersonalizationScore(
        movie: Movie,
        userProfile: UserProfile
    ) -> Double {
        DiscoveryRanking.personalizationScore(movie: movie, userProfile: userProfile)
    }

    /// Ensure diversity in recommendations to prevent filter bubble
    func ensureDiversity<T: MovieProtocol>(
        _ items: [ScoredItem<T>],
        maxPerGenre: Int = 5
    ) -> [ScoredItem<T>] {
        DiscoveryRanking.ensureDiversity(items, maxPerGenre: maxPerGenre, maxItems: maxItemsPerCarousel)
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
            titleSpec: .init(key: "carousel.dailyMix"),
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
            titleSpec: .init(key: "carousel.trendingInGenre", args: [.genre(genre.genreId)]),
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
            titleSpec: .init(key: "carousel.becauseYouLiked", args: [.literal(media.title)]),
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

        return PersonalizedCarousel(
            type: .hiddenGems,
            titleSpec: Self.topGenreTitleSpec(
                key: "carousel.hiddenGems",
                genericKey: "carousel.hiddenGems.generic",
                userProfile: userProfile
            ),
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
            let resolved = await Self.resolveJourneyItem(
                item,
                movieLookup: { [tmdbService] id in
                    try? await tmdbService.getMovieDetails(id: id)
                },
                tvLookup: { [tmdbService] id in
                    guard let show = try? await tmdbService.getTVShowDetails(id: id) else {
                        return nil
                    }
                    return self.mapTVShowToMovie(show)
                }
            )
            if let movie = resolved {
                movies.append(movie)
            }
        }

        return PersonalizedCarousel(
            type: .continueJourney,
            titleSpec: .init(key: "carousel.continueJourney"),
            items: movies,
            descriptions: [:],
            reason: "From your watchlist"
        )
    }

    /// Resolve a watchlist summary through the endpoint matching its media namespace. TMDB movie
    /// and TV ids overlap, so treating every numeric id as a movie is not a safe fallback.
    static func resolveJourneyItem(
        _ item: MediaSummary,
        movieLookup: (Int) async -> Movie?,
        tvLookup: (Int) async -> Movie?
    ) async -> Movie? {
        switch item.mediaType {
        case .tv:
            return await tvLookup(item.id)
        case .movie:
            return await movieLookup(item.id)
        }
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
            titleSpec: .init(key: "carousel.fromSearches"),
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
            titleSpec: .init(key: "carousel.topTVPicks"),
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

        return PersonalizedCarousel(
            type: .staffPicks,
            titleSpec: Self.topGenreTitleSpec(
                key: "carousel.staffPicks",
                genericKey: "carousel.staffPicks.generic",
                userProfile: userProfile
            ),
            items: top20,
            descriptions: [:],
            reason: "Curated classics and modern masterpieces"
        )
    }

    // MARK: - Private Methods - Title Specs

    /// Il titolo di un carosello agganciato al genere preferito dell'utente.
    ///
    /// Quando il genere manca — profilo nuovo, o `preference_id` non numerico — il codice
    /// precedente infilava la stringa inglese `"Your Favorites"` nel `%@` di un template già
    /// tradotto, e usciva "Scelti dallo staff per fan di Your Favorites". Tradurre quel literal non
    /// basterebbe: "per fan di I tuoi preferiti" resta storto in italiano e peggio altrove, perché
    /// ogni lingua regge la preposizione a modo suo. L'unica forma che tiene in tutte è una frase
    /// alternativa intera, da tradurre come tale — da cui `genericKey`.
    ///
    /// Il ramo con genere passa un **id**, non un nome: la traduzione avviene al render, così il
    /// titolo in cache segue l'utente se cambia lingua.
    nonisolated static func topGenreTitleSpec(key: String, genericKey: String, userProfile: UserProfile) -> CarouselTitleSpec {
        // `TMDBGenres.localizedName` filtra anche il genreId 0 che `UserPreferenceManager` produce
        // per un `preference_id` non parsabile: senza questo controllo il titolo direbbe "#0".
        guard let genreId = userProfile.topGenres.first?.genreId,
              TMDBGenres.localizedName(for: genreId) != nil else {
            return .init(key: genericKey)
        }
        return .init(key: key, args: [.genre(genreId)])
    }

    // MARK: - Private Methods - Carousel Catalog

    private func buildDefinitionCatalog(userProfile: UserProfile) -> [CarouselDefinition] {
        // Derive stable per-user seeds from profile signals
        let likedMedia = userProfile.recentActivity.likedMedia
        let preferredDecade = inferDecade(from: likedMedia)
        let previousDecade = max(preferredDecade - 10, 1920)

        let defs: [CarouselDefinition] = [
            // 1. Because You Liked (prio 100)
            CarouselDefinition(
                type: .becauseYouLiked, priority: 100,
                isEligible: { !$0.recentActivity.likedMedia.isEmpty },
                generate: { [weak self] profile, filters, ex in
                    guard let self, let liked = profile.recentActivity.likedMedia.first else { throw PersonalizationError.insufficientData }
                    return try await self.generateSimilarContent(to: liked, userProfile: profile, excluding: ex)
                }
            ),
            // 2. Top in Genre 1 (prio 95)
            CarouselDefinition(
                type: .trendingGenre, priority: 95,
                isEligible: { !$0.topGenres.isEmpty },
                generate: { [weak self] profile, filters, ex in
                    guard let self, let genre = profile.topGenres.first else { throw PersonalizationError.insufficientData }
                    return try await self.generateTopGenre(genre: genre, type: .trendingGenre, userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 3. More from Actor 1 (prio 90)
            CarouselDefinition(
                type: .fromActor, priority: 90,
                isEligible: { !$0.topActors.isEmpty },
                generate: { [weak self] profile, _, ex in
                    guard let self, let actor = profile.topActors.first else { throw PersonalizationError.insufficientData }
                    return try await self.generateFromActor(actor: actor, type: .fromActor, userProfile: profile, excluding: ex)
                }
            ),
            // 4. Hidden Gems (prio 85)
            CarouselDefinition(
                type: .hiddenGems, priority: 85,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateHiddenGems(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 5. Decade Classics (prio 80)
            CarouselDefinition(
                type: .decadeClassics, priority: 80,
                isEligible: { $0.recentActivity.likedMedia.count >= 3 },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateDecadeCarousel(decade: preferredDecade, type: .decadeClassics, userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 6. From Your Searches (prio 75)
            CarouselDefinition(
                type: .fromSearches, priority: 75,
                isEligible: { $0.recentActivity.lastSearchQuery != nil },
                generate: { [weak self] profile, _, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateFromSearches(userProfile: profile, excluding: ex)
                }
            ),
            // 7. Mood Tonight (prio 72)
            CarouselDefinition(
                type: .moodTonight, priority: 72,
                isEligible: { !$0.preferredMoods.isEmpty },
                generate: { [weak self] profile, filters, ex in
                    guard let self, let mood = profile.preferredMoods.first else { throw PersonalizationError.insufficientData }
                    return try await self.generateMoodTonight(mood: mood, userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 8. Continue Your Journey (prio 70)
            CarouselDefinition(
                type: .continueJourney, priority: 70,
                isEligible: { $0.recentActivity.watchlist.count >= 3 },
                generate: { [weak self] profile, _, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateContinueJourney(userProfile: profile, excluding: ex)
                }
            ),
            // 9. Region Spotlight (prio 68)
            CarouselDefinition(
                type: .regionSpotlight, priority: 68,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateRegionSpotlight(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 10. TV Picks for You (prio 65)
            CarouselDefinition(
                type: .topTVPicks, priority: 65,
                isEligible: { $0.contentTypePreference.tvRatio >= 0.2 },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateTopTVPicks(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 11. Award Winners (prio 62)
            CarouselDefinition(
                type: .awardWinners, priority: 62,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateAwardWinners(filters: filters, excluding: ex)
                }
            ),
            // 12. Top in Genre 2 (prio 60)
            CarouselDefinition(
                type: .topGenre2, priority: 60,
                isEligible: { $0.topGenres.count >= 2 },
                generate: { [weak self] profile, filters, ex in
                    guard let self, profile.topGenres.count >= 2 else { throw PersonalizationError.insufficientData }
                    return try await self.generateTopGenre(genre: profile.topGenres[1], type: .topGenre2, userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 13. Hot This Week in Genre 1 (prio 58)
            CarouselDefinition(
                type: .hotThisWeekInGenre, priority: 58,
                isEligible: { !$0.topGenres.isEmpty },
                generate: { [weak self] profile, filters, ex in
                    guard let self, let genre = profile.topGenres.first else { throw PersonalizationError.insufficientData }
                    return try await self.generateHotThisWeekInGenre(genre: genre, filters: filters, excluding: ex)
                }
            ),
            // 14. Quick Watches <90min (prio 55)
            CarouselDefinition(
                type: .quickWatches, priority: 55,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateQuickWatches(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 15. Epic Watches >150min (prio 53)
            CarouselDefinition(
                type: .epicWatches, priority: 53,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateEpicWatches(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 16. International Picks (prio 50)
            CarouselDefinition(
                type: .internationalPicks, priority: 50,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateInternationalPicks(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 17. Throwback Decade (prio 48)
            CarouselDefinition(
                type: .throwbackDecade, priority: 48,
                isEligible: { $0.recentActivity.likedMedia.count >= 3 },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateDecadeCarousel(decade: previousDecade, type: .throwbackDecade, userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 18. From Your AI Chat (prio 45)
            CarouselDefinition(
                type: .fromAIChat, priority: 45,
                isEligible: { _ in true },
                generate: { [weak self] profile, _, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateFromAIChat(userProfile: profile, excluding: ex)
                }
            ),
            // 19. Coming Soon (prio 42)
            CarouselDefinition(
                type: .comingSoon, priority: 42,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateComingSoon(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 20. Trending TV This Week (prio 40)
            CarouselDefinition(
                type: .trendingTVWeek, priority: 40,
                isEligible: { $0.contentTypePreference.tvRatio >= 0.1 },
                generate: { [weak self] profile, _, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateTrendingTVWeek(userProfile: profile, excluding: ex)
                }
            ),
            // 21. Staff Picks (prio 38)
            CarouselDefinition(
                type: .staffPicks, priority: 38,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateStaffPicks(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 22. Critically Acclaimed Recent (prio 35)
            CarouselDefinition(
                type: .criticallyAcclaimedRecent, priority: 35,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateCriticallyAcclaimedRecent(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 23. Top in Genre 3 (prio 32)
            CarouselDefinition(
                type: .topGenre3, priority: 32,
                isEligible: { $0.topGenres.count >= 3 },
                generate: { [weak self] profile, filters, ex in
                    guard let self, profile.topGenres.count >= 3 else { throw PersonalizationError.insufficientData }
                    return try await self.generateTopGenre(genre: profile.topGenres[2], type: .topGenre3, userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 24. Returning TV (prio 28)
            CarouselDefinition(
                type: .returningTV, priority: 28,
                isEligible: { $0.contentTypePreference.tvRatio >= 0.1 },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateReturningTV(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 25. Documentaries (prio 25)
            CarouselDefinition(
                type: .documentaries, priority: 25,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateDocumentaries(userProfile: profile, filters: filters, excluding: ex)
                }
            ),
            // 26. More from Actor 2 (prio 22)
            CarouselDefinition(
                type: .fromActor2, priority: 22,
                isEligible: { $0.topActors.count >= 2 },
                generate: { [weak self] profile, _, ex in
                    guard let self, profile.topActors.count >= 2 else { throw PersonalizationError.insufficientData }
                    return try await self.generateFromActor(actor: profile.topActors[1], type: .fromActor2, userProfile: profile, excluding: ex)
                }
            ),
            // 27. Hot This Week Global (prio 20, ultimate fallback)
            CarouselDefinition(
                type: .hotThisWeek, priority: 20,
                isEligible: { _ in true },
                generate: { [weak self] profile, filters, ex in
                    guard let self else { throw PersonalizationError.noResults }
                    return try await self.generateHotThisWeek(filters: filters, excluding: ex)
                }
            )
        ]

        return defs.sorted { $0.priority > $1.priority }
    }

    // MARK: - Private Helpers

    private func inferDecade(from likedMedia: [MediaSummary]) -> Int {
        DiscoveryQueryDerivation.inferDecade(from: likedMedia)
    }

    private func moodToGenreIds(_ mood: Mood) -> [Int] {
        DiscoveryQueryDerivation.moodToGenreIds(mood)
    }

    private func mapPersonCreditToMovie(_ credit: PersonCredit) -> Movie {
        Movie(
            id: credit.id,
            title: credit.title,
            overview: credit.overview ?? "",
            posterPath: credit.posterPath,
            backdropPath: nil,
            releaseDate: credit.releaseDate,
            voteAverage: credit.voteAverage ?? 0,
            voteCount: 0,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: credit.popularity ?? 0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
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
            titleSpec: .init(key: "carousel.hotThisWeek"),
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
            titleSpec: .init(key: "carousel.awardWinners"),
            items: top20,
            descriptions: [:],
            reason: "Critically acclaimed favorites"
        )
    }

    // MARK: - Private Methods - New Generators

    private func generateTopGenre(genre: GenrePreference, type: CarouselType, userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Top in \(genre.genreName) (excluding \(excluding.count))")
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let rawCandidates: [Movie]
            if let filters, filters.isActive {
                rawCandidates = try await fetchDiscoveredContent(topGenreIds: [genre.genreId], filters: filters, page: page)
            } else {
                let response = try await tmdbService.discoverMovies(withGenre: genre.genreId, sortBy: "popularity.desc", page: page, minRuntime: nil, maxRuntime: nil, minRating: nil, maxRating: nil, releaseDateGte: nil, releaseDateLte: nil, country: nil)
                rawCandidates = response.results
            }
            let newItems = rawCandidates.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: type, titleSpec: .init(key: "carousel.topInGenre", args: [.genre(genre.genreId)]), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Popular \(genre.genreName) films")
    }

    private func generateFromActor(actor: ActorPreference, type: CarouselType, userProfile: UserProfile, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating From Actor \(actor.name) (excluding \(excluding.count))")
        let credits = try await tmdbService.getPersonCombinedCredits(id: actor.actorId)
        let movies = credits.cast
            .filter { $0.mediaType == .movie }
            .map { mapPersonCreditToMovie($0) }
            .filter { !excluding.contains($0.id) }
            .sorted { ($0.popularity) > ($1.popularity) }
        guard movies.count >= 10 else { throw PersonalizationError.noResults }
        let name = try await resolvedActorName(actor)
        return PersonalizedCarousel(type: type, titleSpec: .init(key: "carousel.fromActor", args: [.literal(name)]), items: Array(movies.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Movies featuring \(name)")
    }

    /// Il nome da mostrare nel titolo "Altro con %@".
    ///
    /// `ActorPreference.name` arriva da `user_preferences.preference_name`, che per le preferenze
    /// di categoria `actor` **nessuno scrive mai** (`UserEngagementTracker` salva solo id e score):
    /// il fallback `?? "Unknown"` di `UserPreferenceManager` vinceva sempre, e il carosello si
    /// intitolava "Altro con Unknown" in ogni lingua. Qui il nome vero si chiede a TMDB — la
    /// risposta è già in URLCache nella stragrande maggioranza dei casi, e il carosello ha appena
    /// fatto una richiesta per lo stesso id.
    ///
    /// Se anche TMDB non lo sa, il carosello **non si mostra**: un titolo senza soggetto è peggio
    /// di un carosello in meno.
    private func resolvedActorName(_ actor: ActorPreference) async throws -> String {
        let stored = actor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty && stored.lowercased() != "unknown" { return stored }

        guard let details = try? await tmdbService.getPersonDetails(id: actor.actorId) else {
            throw PersonalizationError.noResults
        }
        let fetched = details.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fetched.isEmpty else { throw PersonalizationError.noResults }
        return fetched
    }

    private func generateDecadeCarousel(decade: Int, type: CarouselType, userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating \(decade)s carousel (excluding \(excluding.count))")
        let gteDate = "\(decade)-01-01"
        let lteDate = "\(decade + 9)-12-31"
        let topGenreId = userProfile.topGenres.first?.genreId
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let response = try await tmdbService.discoverMovies(withGenre: topGenreId, sortBy: "vote_average.desc", page: page, minRuntime: nil, maxRuntime: nil, minRating: 7.0, maxRating: nil, releaseDateGte: gteDate, releaseDateLte: lteDate, country: nil)
            let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        // Il decennio viaggia come numero: "2020s" è grammatica inglese, in italiano si dice
        // "anni 2020" e in altre lingue cambia ancora. Ci pensa `Arg.decade` al render.
        let titleSpec: CarouselTitleSpec = type == .throwbackDecade
            ? .init(key: "carousel.throwback", args: [.decade(decade)])
            : .init(key: "carousel.decadeClassics", args: [.decade(decade)])
        return PersonalizedCarousel(type: type, titleSpec: titleSpec, items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Top-rated films from the \(decade)s")
    }

    private func generateMoodTonight(mood: Mood, userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Mood Tonight (\(mood.rawValue)) (excluding \(excluding.count))")
        let genreIds = moodToGenreIds(mood)
        var allCandidates: [Movie] = []
        outer: for genreId in genreIds.prefix(2) {
            for page in 1...3 {
                let response = try await tmdbService.discoverMovies(withGenre: genreId, sortBy: "popularity.desc", page: page, minRuntime: nil, maxRuntime: nil, minRating: 6.5, maxRating: nil, releaseDateGte: nil, releaseDateLte: nil, country: nil)
                let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
                allCandidates.append(contentsOf: newItems)
                if allCandidates.count >= maxItemsPerCarousel { break outer }
            }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .moodTonight, titleSpec: .init(key: "carousel.moodTonight", args: [.localizedKey(mood.localizationKey)]), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Perfect for when you're feeling \(mood.rawValue)")
    }

    private func generateRegionSpotlight(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        // Il paese scelto in Impostazioni, non quello del dispositivo: è lo stesso che l'app manda
        // a TMDB come `region`, e un carosello "In evidenza: X" che nomina un paese diverso da
        // quello dei risultati confonde e basta.
        let countryCode = LocalizationManager.shared.appLocale.region?.identifier ?? "US"
        Logger.debug("[DiscoveryPersonalizationService] Generating Region Spotlight (\(countryCode)) (excluding \(excluding.count))")
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let response = try await tmdbService.discoverMovies(withGenre: userProfile.topGenres.first?.genreId, sortBy: "vote_average.desc", page: page, minRuntime: nil, maxRuntime: nil, minRating: 7.0, maxRating: nil, releaseDateGte: nil, releaseDateLte: nil, country: countryCode)
            let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .regionSpotlight, titleSpec: .init(key: "carousel.regionSpotlight", args: [.region(countryCode)]), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Popular in \(countryCode)")
    }

    private func generateHotThisWeekInGenre(genre: GenrePreference, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Hot This Week in \(genre.genreName) (excluding \(excluding.count))")
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let trending = try await tmdbService.getTrendingMovies(timeWindow: .week, page: page)
            let filtered = trending.results.filter { c in (c.genreIds?.contains(genre.genreId) ?? false) && !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: filtered)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .hotThisWeekInGenre, titleSpec: .init(key: "carousel.hotThisWeekInGenre", args: [.genre(genre.genreId)]), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Trending \(genre.genreName) films this week")
    }

    private func generateQuickWatches(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Quick Watches (excluding \(excluding.count))")
        let topGenreId = userProfile.topGenres.first?.genreId
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let response = try await tmdbService.discoverMovies(withGenre: topGenreId, sortBy: "popularity.desc", page: page, minRuntime: nil, maxRuntime: 90, minRating: 6.0, maxRating: nil, releaseDateGte: nil, releaseDateLte: nil, country: nil)
            let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .quickWatches, titleSpec: .init(key: "carousel.quickWatches"), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Great films under 90 minutes")
    }

    private func generateEpicWatches(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Epic Watches (excluding \(excluding.count))")
        let topGenreId = userProfile.topGenres.first?.genreId
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let response = try await tmdbService.discoverMovies(withGenre: topGenreId, sortBy: "popularity.desc", page: page, minRuntime: 150, maxRuntime: nil, minRating: 6.5, maxRating: nil, releaseDateGte: nil, releaseDateLte: nil, country: nil)
            let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .epicWatches, titleSpec: .init(key: "carousel.epicWatches"), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Epic films over 2.5 hours")
    }

    private func generateInternationalPicks(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating International Picks (excluding \(excluding.count))")
        let countryCodes = ["FR", "ES", "JP", "KR", "DE", "IT", "BR"]
        let topGenreId = userProfile.topGenres.first?.genreId
        var allCandidates: [Movie] = []
        for country in countryCodes {
            if allCandidates.count >= maxItemsPerCarousel { break }
            let response = try await tmdbService.discoverMovies(withGenre: topGenreId, sortBy: "vote_average.desc", page: 1, minRuntime: nil, maxRuntime: nil, minRating: 7.0, maxRating: nil, releaseDateGte: nil, releaseDateLte: nil, country: country)
            let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .internationalPicks, titleSpec: .init(key: "carousel.internationalPicks"), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Hidden gems from world cinema")
    }

    private func generateFromAIChat(userProfile: UserProfile, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating From AI Chat (excluding \(excluding.count))")
        let rows = try await sqliteService.queryRaw("""
            SELECT mentioned_media_ids FROM ai_conversation_history
            WHERE user_id = ? AND mentioned_media_ids IS NOT NULL AND mentioned_media_ids != ''
            ORDER BY created_at DESC LIMIT 20
        """, parameters: [userProfile.userId])
        var mediaIds: [Int] = []
        var seenIds = Set<Int>()
        for row in rows {
            guard let json = row["mentioned_media_ids"] as? String,
                  let data = json.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([Int].self, from: data) else { continue }
            for id in ids where seenIds.insert(id).inserted { mediaIds.append(id) }
            if mediaIds.count >= 50 { break }
        }
        guard !mediaIds.isEmpty else { throw PersonalizationError.insufficientData }
        var movies: [Movie] = []
        for id in mediaIds where !excluding.contains(id) {
            if movies.count >= maxItemsPerCarousel * 2 { break }
            if let movie = try? await tmdbService.getMovieDetails(id: id) { movies.append(movie) }
        }
        guard movies.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .fromAIChat, titleSpec: .init(key: "carousel.fromAIChat"), items: Array(movies.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Mentioned in your AI conversations")
    }

    private func generateComingSoon(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Coming Soon (excluding \(excluding.count))")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let tomorrowString = formatter.string(from: tomorrow)
        let topGenreId = userProfile.topGenres.first?.genreId
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let response = try await tmdbService.discoverMovies(withGenre: topGenreId, sortBy: "primary_release_date.asc", page: page, minRuntime: nil, maxRuntime: nil, minRating: nil, maxRating: nil, releaseDateGte: tomorrowString, releaseDateLte: nil, country: nil)
            let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .comingSoon, titleSpec: .init(key: "carousel.comingSoon"), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Coming to screens soon")
    }

    private func generateTrendingTVWeek(userProfile: UserProfile, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Trending TV Week (excluding \(excluding.count))")
        let topGenreIds = Set(userProfile.topGenres.prefix(3).map(\.genreId))
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let shows = try await tmdbService.getTrendingTVShows(timeWindow: .week, page: page)
            let filtered = shows.results
                .filter { topGenreIds.isEmpty || ($0.genreIds?.contains(where: { topGenreIds.contains($0) }) ?? false) }
                .map(mapTVShowToMovie)
                .filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: filtered)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .trendingTVWeek, titleSpec: .init(key: "carousel.trendingTVWeek"), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Trending TV shows this week")
    }

    private func generateCriticallyAcclaimedRecent(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Critically Acclaimed Recent (excluding \(excluding.count))")
        let currentYear = Calendar.current.component(.year, from: Date())
        let threeYearsAgo = "\(currentYear - 2)-01-01"
        let topGenreId = userProfile.topGenres.first?.genreId
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let response = try await tmdbService.discoverMovies(withGenre: topGenreId, sortBy: "vote_average.desc", page: page, minRuntime: nil, maxRuntime: nil, minRating: 7.5, maxRating: nil, releaseDateGte: threeYearsAgo, releaseDateLte: nil, country: nil)
            let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        let yearRange = "\(currentYear - 2)–\(currentYear)"
        return PersonalizedCarousel(type: .criticallyAcclaimedRecent, titleSpec: .init(key: "carousel.criticallyAcclaimedRecent", args: [.literal(yearRange)]), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Recent critically acclaimed films")
    }

    private func generateReturningTV(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Returning TV (excluding \(excluding.count))")
        let topGenreIds = Array(userProfile.topGenres.prefix(3).map(\.genreId))
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let rawCandidates: [Movie]
            if let filters, filters.isActive {
                rawCandidates = try await fetchDiscoveredTVContent(topGenreIds: topGenreIds, filters: filters, page: page, forceSortBy: .releaseDateDesc)
            } else {
                let response = try await tmdbService.discoverTVShows(withGenre: topGenreIds.first, sortBy: "first_air_date.desc", page: page, minRating: 6.5, maxRating: nil, firstAirDateGte: nil, firstAirDateLte: nil, country: nil)
                rawCandidates = response.results.map(mapTVShowToMovie)
            }
            let newItems = rawCandidates.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .returningTV, titleSpec: .init(key: "carousel.returningTV"), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "TV shows airing recently")
    }

    private func generateDocumentaries(userProfile: UserProfile, filters: GlobalDiscoveryFilters?, excluding: Set<Int> = []) async throws -> PersonalizedCarousel {
        Logger.debug("[DiscoveryPersonalizationService] Generating Documentaries (excluding \(excluding.count))")
        var allCandidates: [Movie] = []
        for page in 1...5 {
            let response = try await tmdbService.discoverMovies(withGenre: 99, sortBy: "vote_average.desc", page: page, minRuntime: nil, maxRuntime: nil, minRating: 7.0, maxRating: nil, releaseDateGte: nil, releaseDateLte: nil, country: nil)
            let newItems = response.results.filter { c in !excluding.contains(c.id) && !allCandidates.contains(where: { $0.id == c.id }) }
            allCandidates.append(contentsOf: newItems)
            if allCandidates.count >= maxItemsPerCarousel { break }
        }
        guard allCandidates.count >= 10 else { throw PersonalizationError.noResults }
        return PersonalizedCarousel(type: .documentaries, titleSpec: .init(key: "carousel.documentaries"), items: Array(allCandidates.prefix(maxItemsPerCarousel)), descriptions: [:], reason: "Award-winning documentaries")
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
        DiscoveryQueryDerivation.yearDateRange(filters: filters)
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

    private var embeddingModelName: String { "zai-glm-4.7" }

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
        DiscoveryRanking.cosineSimilarity(a, b)
    }

    // MARK: - Private Methods - Caching

    /// Load personalized carousels from database cache
    /// Returns nil if cache is expired or doesn't exist (unless ignoreExpiry is true)
    private func loadFromCache(userId: String, ignoreExpiry: Bool = false) async throws -> [PersonalizedCarousel]? {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let nowString = isoFormatter.string(from: now)

        let (sql, params): (String, [Any]) = ignoreExpiry
            ? ("SELECT * FROM personalized_discovery WHERE user_id = ? ORDER BY COALESCE(carousel_order, 999) ASC, position ASC", [userId])
            : ("SELECT * FROM personalized_discovery WHERE user_id = ? AND expires_at > ? ORDER BY COALESCE(carousel_order, 999) ASC, position ASC", [userId, nowString])

        let rows = try await sqliteService.queryRaw(sql, parameters: params)

        guard !rows.isEmpty else {
            Logger.debug("[DiscoveryPersonalizationService] No cache found or cache expired")
            return nil
        }

        Logger.debug("[DiscoveryPersonalizationService] Found \(rows.count) cached items, loading movie data...")

        var carouselMovies: [String: [(movie: Movie, position: Int)]] = [:]
        var carouselMetadata: [String: (titleSpec: CarouselTitleSpec, reason: String)] = [:]
        var descriptions: [String: [String: String]] = [:]
        var carouselOrder: [String: Int] = [:]

        for row in rows {
            guard let typeString = row["carousel_type"] as? String,
                  let position = row["position"] as? Int else { continue }
            // Rows without a title spec were written before this migration — treat as cache miss.
            guard let specJson = row["carousel_title_spec"] as? String,
                  let specData = specJson.data(using: .utf8),
                  let titleSpec = try? JSONDecoder().decode(CarouselTitleSpec.self, from: specData) else {
                Logger.info("[DiscoveryPersonalizationService] Cache row missing title spec - will regenerate")
                return nil
            }
            let reason = row["reason"] as? String ?? ""
            let order = row["carousel_order"] as? Int ?? 999
            guard let movieDataString = row["media_data"] as? String,
                  !movieDataString.isEmpty,
                  let movieData = movieDataString.data(using: .utf8),
                  let validMovie = try? JSONDecoder().decode(Movie.self, from: movieData) else {
                Logger.warning("[DiscoveryPersonalizationService] Cache missing movie data - will regenerate")
                return nil
            }
            if carouselMovies[typeString] == nil {
                carouselMovies[typeString] = []
                carouselMetadata[typeString] = (titleSpec: titleSpec, reason: reason)
                descriptions[typeString] = [:]
            }
            carouselMovies[typeString]?.append((movie: validMovie, position: position))
            carouselOrder[typeString] = min(carouselOrder[typeString] ?? Int.max, order)
            if let desc = row["description"] as? String { descriptions[typeString]?[String(validMovie.id)] = desc }
        }

        Logger.debug("[DiscoveryPersonalizationService] Loaded \(carouselMovies.values.flatMap { $0 }.count) cached items")

        var carousels: [PersonalizedCarousel] = []
        for (typeString, movieItems) in carouselMovies {
            guard let type = CarouselType(rawValue: typeString), let metadata = carouselMetadata[typeString] else { continue }
            let sortedMovies = deduplicateMoviesById(movieItems.sorted { $0.position < $1.position }.map(\.movie))
            guard !sortedMovies.isEmpty else { continue }
            carousels.append(PersonalizedCarousel(type: type, titleSpec: metadata.titleSpec, items: sortedMovies, descriptions: descriptions[typeString] ?? [:], reason: metadata.reason))
        }
        carousels.sort { (carouselOrder[$0.type.rawValue] ?? 999) < (carouselOrder[$1.type.rawValue] ?? 999) }

        Logger.info("[DiscoveryPersonalizationService] ✅ Loaded \(carousels.count) ordered carousels from cache")
        return carousels.isEmpty ? nil : carousels
    }

    /// Load personalized carousels from database cache using device id.
    private func loadFromCache(deviceId: String, ignoreExpiry: Bool = false) async throws -> [PersonalizedCarousel]? {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let nowString = isoFormatter.string(from: now)

        let (sql, params): (String, [Any]) = ignoreExpiry
            ? ("SELECT * FROM personalized_discovery WHERE device_id = ? ORDER BY COALESCE(carousel_order, 999) ASC, position ASC", [deviceId])
            : ("SELECT * FROM personalized_discovery WHERE device_id = ? AND expires_at > ? ORDER BY COALESCE(carousel_order, 999) ASC, position ASC", [deviceId, nowString])

        let rows = try await sqliteService.queryRaw(sql, parameters: params)

        guard !rows.isEmpty else {
            Logger.debug("[DiscoveryPersonalizationService] No device cache found or cache expired")
            return nil
        }

        Logger.debug("[DiscoveryPersonalizationService] Found \(rows.count) cached items (device)")

        var carouselMovies: [String: [(movie: Movie, position: Int)]] = [:]
        var carouselMetadata: [String: (titleSpec: CarouselTitleSpec, reason: String)] = [:]
        var descriptions: [String: [String: String]] = [:]
        var carouselOrder: [String: Int] = [:]

        for row in rows {
            guard let typeString = row["carousel_type"] as? String,
                  let position = row["position"] as? Int else { continue }
            guard let specJson = row["carousel_title_spec"] as? String,
                  let specData = specJson.data(using: .utf8),
                  let titleSpec = try? JSONDecoder().decode(CarouselTitleSpec.self, from: specData) else {
                Logger.info("[DiscoveryPersonalizationService] Device cache row missing title spec - will regenerate")
                return nil
            }
            let reason = row["reason"] as? String ?? ""
            let order = row["carousel_order"] as? Int ?? 999
            guard let movieDataString = row["media_data"] as? String,
                  !movieDataString.isEmpty,
                  let movieData = movieDataString.data(using: .utf8),
                  let validMovie = try? JSONDecoder().decode(Movie.self, from: movieData) else {
                Logger.warning("[DiscoveryPersonalizationService] Device cache missing movie data - will regenerate")
                return nil
            }
            if carouselMovies[typeString] == nil {
                carouselMovies[typeString] = []
                carouselMetadata[typeString] = (titleSpec: titleSpec, reason: reason)
                descriptions[typeString] = [:]
            }
            carouselMovies[typeString]?.append((movie: validMovie, position: position))
            carouselOrder[typeString] = min(carouselOrder[typeString] ?? Int.max, order)
            if let desc = row["description"] as? String { descriptions[typeString]?[String(validMovie.id)] = desc }
        }

        var carousels: [PersonalizedCarousel] = []
        for (typeString, movieItems) in carouselMovies {
            guard let type = CarouselType(rawValue: typeString), let metadata = carouselMetadata[typeString] else { continue }
            let sortedMovies = deduplicateMoviesById(movieItems.sorted { $0.position < $1.position }.map(\.movie))
            guard !sortedMovies.isEmpty else { continue }
            carousels.append(PersonalizedCarousel(type: type, titleSpec: metadata.titleSpec, items: sortedMovies, descriptions: descriptions[typeString] ?? [:], reason: metadata.reason))
        }
        carousels.sort { (carouselOrder[$0.type.rawValue] ?? 999) < (carouselOrder[$1.type.rawValue] ?? 999) }

        Logger.info("[DiscoveryPersonalizationService] ✅ Loaded \(carousels.count) ordered carousels from device cache")
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

        // Delete old rows and insert new ones atomically so readers never see an empty cache.
        try? sqliteService.transaction { txn in
            try txn.delete("personalized_discovery", where: "user_id = ?", parameters: [userId], hard: true)
            for (carouselIndex, carousel) in carousels.enumerated() {
                let batchIndex = carouselIndex / 10
                for (itemIndex, movie) in carousel.items.enumerated() {
                    let id = UUID().uuidString.lowercased()
                    let description = carousel.descriptions[String(movie.id)] ?? ""
                    let movieData: String? = (try? JSONEncoder().encode(movie)).flatMap { String(data: $0, encoding: .utf8) }
                    let titleSpecJson = (try? JSONEncoder().encode(carousel.titleSpec)).flatMap { String(data: $0, encoding: .utf8) }
                    let values: [String: Any] = [
                        "id": id,
                        "user_id": userId,
                        "device_id": deviceId,
                        "carousel_type": carousel.type.rawValue,
                        "carousel_title": carousel.title,
                        "carousel_title_spec": titleSpecJson ?? NSNull(),
                        "media_id": movie.id,
                        "media_type": "movie",
                        "media_data": movieData ?? NSNull(),
                        "position": itemIndex,
                        "carousel_order": carouselIndex,
                        "batch_index": batchIndex,
                        "score": carousel.items.count - itemIndex,
                        "reason": carousel.reason,
                        "description": description,
                        "generated_at": now,
                        "expires_at": expiresAt
                    ]
                    try txn.insert("personalized_discovery", values: values)
                }
            }
        }

        Logger.debug("[DiscoveryPersonalizationService] Cached \(carousels.count) carousels to database")
    }

    private func deduplicateMoviesById(_ movies: [Movie]) -> [Movie] {
        DiscoveryRanking.deduplicateMoviesById(movies)
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
                titleSpec: carousel.titleSpec,
                items: carousel.items,
                descriptions: merged,
                reason: carousel.reason
            )
        }
    }

    private func collectUniqueMovies(from carousels: [PersonalizedCarousel]) -> [Movie] {
        DiscoveryRanking.collectUniqueMovies(from: carousels)
    }
}

// MARK: - Supporting Models

struct CarouselTitleSpec: Codable {
    let key: String
    let args: [Arg]

    init(key: String, args: [Arg] = []) {
        self.key = key
        self.args = args
    }

    /// Un argomento del titolo. Tutti i casi tranne `.literal` sono **dati**, non testo: si
    /// traducono al momento del render, così un titolo salvato in cache resta corretto anche se
    /// l'utente cambia lingua dopo.
    ///
    /// `.literal` resta per ciò che non si traduce davvero — nomi propri (titolo di un film, nome
    /// di un attore) e intervalli numerici. Passarci un nome di genere o un mood è il bug che
    /// produceva "Il meglio di Science Fiction".
    enum Arg: Codable {
        case literal(String)
        case region(String)  // ISO country code — resolved at render time
        case genre(Int)      // TMDB genre id
        case decade(Int)     // anno d'inizio del decennio, es. 2020
        case localizedKey(String) // chiave di Localizable.strings da risolvere in loco

        private enum CodingKeys: String, CodingKey { case type, value }
        private enum ArgType: String, Codable { case literal, region, genre, decade, localizedKey }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let t = try c.decode(ArgType.self, forKey: .type)
            let v = try c.decode(String.self, forKey: .value)
            switch t {
            case .literal: self = .literal(v)
            case .region: self = .region(v)
            // Un id non numerico verrebbe da una riga di cache corrotta: meglio degradare a testo
            // che far fallire il decode e perdere l'intero carosello.
            case .genre: self = Int(v).map { .genre($0) } ?? .literal(v)
            case .decade: self = Int(v).map { .decade($0) } ?? .literal(v)
            case .localizedKey: self = .localizedKey(v)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .literal(let s):
                try c.encode(ArgType.literal, forKey: .type)
                try c.encode(s, forKey: .value)
            case .region(let code):
                try c.encode(ArgType.region, forKey: .type)
                try c.encode(code, forKey: .value)
            case .genre(let id):
                try c.encode(ArgType.genre, forKey: .type)
                try c.encode(String(id), forKey: .value)
            case .decade(let year):
                try c.encode(ArgType.decade, forKey: .type)
                try c.encode(String(year), forKey: .value)
            case .localizedKey(let key):
                try c.encode(ArgType.localizedKey, forKey: .type)
                try c.encode(key, forKey: .value)
            }
        }
    }

    func resolve() -> String {
        if args.isEmpty { return key.localized }
        let resolved = args.map { arg -> CVarArg in
            switch arg {
            case .literal(let s): return s
            case .region(let code):
                return LocalizationManager.shared.appLocale.localizedString(forRegionCode: code) ?? code
            case .genre(let id): return TMDBGenres.displayName(for: id)
            // "anni %d" / "%ds": il suffisso del decennio è grammatica, non un numero.
            case .decade(let year): return String(format: "carousel.arg.decade".localized, year)
            case .localizedKey(let key): return key.localized
            }
        }
        return String(format: key.localized, arguments: resolved)
    }
}

struct PersonalizedCarousel {
    let type: CarouselType
    let titleSpec: CarouselTitleSpec
    let items: [Movie]
    let descriptions: [String: String] // movieId -> description
    let reason: String

    var title: String { titleSpec.resolve() }
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
    // New personalized carousels
    case fromActor = "from_actor"
    case decadeClassics = "decade_classics"
    case moodTonight = "mood_tonight"
    case regionSpotlight = "region_spotlight"
    case topGenre2 = "top_genre_2"
    case topGenre3 = "top_genre_3"
    case hotThisWeekInGenre = "hot_this_week_genre"
    case quickWatches = "quick_watches"
    case epicWatches = "epic_watches"
    case internationalPicks = "international_picks"
    case throwbackDecade = "throwback_decade"
    case fromAIChat = "from_ai_chat"
    case comingSoon = "coming_soon"
    case trendingTVWeek = "trending_tv_week"
    case criticallyAcclaimedRecent = "critically_acclaimed_recent"
    case returningTV = "returning_tv"
    case documentaries = "documentaries"
    case fromActor2 = "from_actor_2"
}

struct CarouselCandidate {
    let type: CarouselType
    let relevance: Double
    let generator: () async throws -> PersonalizedCarousel
}

private struct CarouselDefinition {
    let type: CarouselType
    let priority: Int
    let isEligible: (UserProfile) -> Bool
    let generate: (UserProfile, GlobalDiscoveryFilters?, Set<Int>) async throws -> PersonalizedCarousel
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
