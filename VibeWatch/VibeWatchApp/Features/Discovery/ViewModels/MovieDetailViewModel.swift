import Foundation

@MainActor
class MovieDetailViewModel: ObservableObject {
    @Published var movie: Movie?
    @Published var credits: Credits?
    @Published var videos: [Video] = []
    @Published var watchProviders: CountryProviders?
    @Published var similarMovies: [Movie] = []
    @Published var imdbId: String?
    @Published var isLoading = false
    @Published var error: AppError?
    
    private let tmdbService = TMDBService.shared
    private let watchmodeService = WatchmodeService.shared
    private let detailCache = DetailCacheService.shared
    private let quotaService = ClipQuotaService.shared
    private let movieId: Int

    init(movieId: Int) {
        self.movieId = movieId
    }

    func loadMovieDetails() async {
        isLoading = true
        error = nil

        // Step 1: Check if user is PRO (offline mode only for PRO users)
        let isProUser = await quotaService.checkIsProUser()
        print("🔍 [MovieDetail] PRO user status: \(isProUser)")

        // Step 2: Try to load from cache first (PRO users only)
        if isProUser {
            do {
                if let cached = try await detailCache.getCachedMovieDetails(movieId: movieId) {
                    print("📦 [MovieDetail] Loaded from cache (PRO user): \(cached.movie.title)")
                    self.movie = cached.movie
                    self.credits = cached.credits
                    self.videos = cached.videos
                    self.watchProviders = cached.watchProviders
                    self.similarMovies = cached.similarMovies
                    self.imdbId = cached.movie.imdbId
                    isLoading = false
                    // Note: We still have cached data, so no error state
                    return
                } else {
                    print("⚠️ [MovieDetail] No cached data found for movie ID \(movieId)")
                }
            } catch {
                print("⚠️ [MovieDetail] Cache retrieval failed: \(error.localizedDescription)")
            }
        } else {
            print("📵 [MovieDetail] Non-PRO user - skipping cache")
        }

        // Step 2: Cache miss or expired - fetch from network with retry logic
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                // Try to load all details from network
                try await attemptLoadMovieDetails()

                // Step 3: Cache the successfully fetched data (PRO users only)
                if isProUser, let movie = self.movie {
                    try? await detailCache.cacheMovieDetails(
                        movie: movie,
                        credits: self.credits,
                        videos: self.videos,
                        watchProviders: self.watchProviders,
                        similarMovies: self.similarMovies,
                        imdbId: self.imdbId
                    )
                }

                // Success - clear any error and return
                error = nil
                isLoading = false
                return
            } catch {
                lastError = error
                print("⚠️ [MovieDetail] Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")

                // Don't retry on the last attempt
                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1)) // 1s, 2s
                    print("🔄 [MovieDetail] Retrying in \(delay)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // All attempts failed - show error
        self.error = AppError.network(lastError ?? NSError(domain: "MovieDetailViewModel", code: -1))
        isLoading = false
    }

    private func attemptLoadMovieDetails() async throws {
        async let movieTask = tmdbService.getMovieDetails(id: movieId)
        async let creditsTask = tmdbService.getMovieCredits(id: movieId)
        async let videosTask = tmdbService.getMovieVideos(id: movieId)
        async let providersTask = tmdbService.getMovieWatchProviders(id: movieId)
        async let similarTask = tmdbService.getSimilarMovies(id: movieId, page: 1)
        async let externalIdsTask = tmdbService.getMovieExternalIds(id: movieId)

        let (movieData, creditsData, videosData, providersData, similarData, externalIdsData) = try await (
            movieTask, creditsTask, videosTask, providersTask, similarTask, externalIdsTask
        )

        movie = movieData
        credits = creditsData
        videos = videosData.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
        imdbId = externalIdsData.imdbId

        // Use current country for watch providers
        let country = LocalizationManager.shared.currentCountry.id
        let baseProviders = providersData.results[country]

        similarMovies = Array(similarData.results.prefix(10))

        print("🎬 [MovieDetail] IMDB ID: \(imdbId ?? "nil")")
        print("🔗 [MovieDetail] JustWatch Link: \(baseProviders?.link ?? "nil")")

        // Fetch streaming availability pricing and quality data (non-blocking)
        // Always set watchProviders first to prevent errors
        watchProviders = baseProviders

        do {
            let watchmodeSources = try await watchmodeService.getStreamingSources(
                tmdbId: movieId,
                type: .movie,
                region: country
            )

            print("✅ [Watchmode] Fetched \(watchmodeSources.count) sources")

            // Merge Watchmode data with TMDb providers
            if var providers = baseProviders {
                providers = mergeWatchmodeData(providers: providers, sources: watchmodeSources)
                watchProviders = providers
            }
        } catch {
            print("⚠️ [Watchmode] Failed to fetch pricing data: \(error.localizedDescription)")
            // Already set watchProviders above, so we're good
        }

        // Debug: Print provider information including price and quality
        if let providers = watchProviders {
            if let flatrate = providers.flatrate {
                print("📺 [MovieDetail] Streaming Providers: \(flatrate.count)")
                flatrate.forEach { provider in
                    print("   - \(provider.providerName) | Price: \(provider.price?.displayPrice ?? "nil") | Quality: \(provider.formattedQuality ?? "nil")")
                }
            }
            if let rent = providers.rent {
                print("💰 [MovieDetail] Rent Providers: \(rent.count)")
                rent.forEach { provider in
                    print("   - \(provider.providerName) | Price: \(provider.price?.displayPrice ?? "nil") | Quality: \(provider.formattedQuality ?? "nil")")
                }
            }
            if let buy = providers.buy {
                print("🛒 [MovieDetail] Buy Providers: \(buy.count)")
                buy.forEach { provider in
                    print("   - \(provider.providerName) | Price: \(provider.price?.displayPrice ?? "nil") | Quality: \(provider.formattedQuality ?? "nil")")
                }
            }
        }
    }
    
    var director: Crew? {
        credits?.crew.first { $0.job == "Director" }
    }
    
    var mainCast: [Cast] {
        Array(credits?.cast.prefix(10) ?? [])
    }
    
    var trailer: Video? {
        videos.first
    }
    
    // MARK: - Helper Methods
    
    /// Merge Watchmode pricing/quality data with TMDb providers
    private func mergeWatchmodeData(providers: CountryProviders, sources: [WatchmodeSource]) -> CountryProviders {
        var updatedProviders = providers
        
        // Update streaming providers
        if let flatrate = providers.flatrate {
            updatedProviders.flatrate = flatrate.map { provider in
                enrichProvider(provider, with: sources, type: "sub")
            }
        }
        
        // Update rent providers
        if let rent = providers.rent {
            updatedProviders.rent = rent.map { provider in
                enrichProvider(provider, with: sources, type: "rent")
            }
        }
        
        // Update buy providers
        if let buy = providers.buy {
            updatedProviders.buy = buy.map { provider in
                enrichProvider(provider, with: sources, type: "buy")
            }
        }
        
        return updatedProviders
    }
    
    /// Enrich a provider with Watchmode data
    private func enrichProvider(_ provider: Provider, with sources: [WatchmodeSource], type: String) -> Provider {
        // Try to find matching Watchmode source by name
        guard let matchingSource = sources.first(where: { source in
            source.type == type && providerNamesMatch(provider.providerName, source.name)
        }) else {
            // Debug: Print why this provider didn't match
            let availableNames = sources.filter { $0.type == type }.map { $0.name }.joined(separator: ", ")
            print("   ⚠️ No match for '\(provider.providerName)' (type: \(type)). Available: [\(availableNames)]")
            return provider
        }
        
        // Create price info if available
        var priceInfo: PriceInfo? = nil
        if let price = matchingSource.price, let currency = matchingSource.currency {
            priceInfo = PriceInfo(
                value: price,
                currency: currency,
                formatted: matchingSource.formattedPrice
            )
        }
        
        // Create enriched provider with pricing and quality
        return Provider(
            providerId: provider.providerId,
            providerName: provider.providerName,
            logoPath: provider.logoPath,
            displayPriority: provider.displayPriority,
            price: priceInfo,
            quality: matchingSource.format,
            presentationType: provider.presentationType
        )
    }
    
    /// Check if provider names match (fuzzy matching with aliases)
    private func providerNamesMatch(_ tmdbName: String, _ watchmodeName: String) -> Bool {
        // Normalize both names
        let normalized1 = normalizeProviderName(tmdbName)
        let normalized2 = normalizeProviderName(watchmodeName)
        
        // Direct match
        if normalized1 == normalized2 {
            return true
        }
        
        // Substring match
        if normalized1.contains(normalized2) || normalized2.contains(normalized1) {
            return true
        }
        
        // Check known aliases
        if areKnownAliases(normalized1, normalized2) {
            return true
        }
        
        return false
    }
    
    /// Normalize provider name for comparison
    private func normalizeProviderName(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "+", with: "plus")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "tv", with: "")
            .replacingOccurrences(of: "video", with: "")
    }
    
    /// Check if two names are known aliases
    private func areKnownAliases(_ name1: String, _ name2: String) -> Bool {
        let aliasGroups: [[String]] = [
            ["amazon", "prime", "primevideo", "amazonvideo"],
            ["apple", "appletv", "appletvplus"],
            ["paramount", "paramountplus"],
            ["hbo", "hbomax", "max"],
            ["disney", "disneyplus"],
            ["google", "googleplay", "googleplaymovies"],
            ["rakuten", "rakutentv"],
            ["chili"],
            ["timvision"],
            ["mediaset", "mediasetinfinity"],
            ["netflix"],
            ["hulu"]
        ]
        
        for group in aliasGroups {
            if group.contains(where: { name1.contains($0) }) &&
               group.contains(where: { name2.contains($0) }) {
                return true
            }
        }
        
        return false
    }
}

@MainActor
class TVShowDetailViewModel: ObservableObject {
    @Published var tvShow: TVShow?
    @Published var credits: Credits?
    @Published var videos: [Video] = []
    @Published var watchProviders: CountryProviders?
    @Published var similarShows: [TVShow] = []
    @Published var imdbId: String?
    @Published var isLoading = false
    @Published var error: AppError?
    
    private let tmdbService = TMDBService.shared
    private let watchmodeService = WatchmodeService.shared
    private let detailCache = DetailCacheService.shared
    private let quotaService = ClipQuotaService.shared
    private let tvShowId: Int

    init(tvShowId: Int) {
        self.tvShowId = tvShowId
    }

    func loadTVShowDetails() async {
        isLoading = true
        error = nil

        // Step 1: Check if user is PRO (offline mode only for PRO users)
        let isProUser = await quotaService.checkIsProUser()

        // Step 2: Try to load from cache first (PRO users only)
        if isProUser, let cached = try? await detailCache.getCachedTVShowDetails(tvShowId: tvShowId) {
            print("📦 [TVShowDetail] Loaded from cache (PRO user): \(cached.tvShow.name)")
            self.tvShow = cached.tvShow
            self.credits = cached.credits
            self.videos = cached.videos
            self.watchProviders = cached.watchProviders
            self.similarShows = cached.similarShows
            self.imdbId = cached.tvShow.imdbId
            isLoading = false
            // Note: We still have cached data, so no error state
            return
        }

        // Step 2: Cache miss or expired - fetch from network with retry logic
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                // Try to load all details from network
                try await attemptLoadTVShowDetails()

                // Step 3: Cache the successfully fetched data (PRO users only)
                if isProUser, let tvShow = self.tvShow {
                    try? await detailCache.cacheTVShowDetails(
                        tvShow: tvShow,
                        credits: self.credits,
                        videos: self.videos,
                        watchProviders: self.watchProviders,
                        similarShows: self.similarShows,
                        imdbId: self.imdbId
                    )
                }

                // Success - clear any error and return
                error = nil
                isLoading = false
                return
            } catch {
                lastError = error
                print("⚠️ [TVShowDetail] Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")

                // Don't retry on the last attempt
                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1)) // 1s, 2s
                    print("🔄 [TVShowDetail] Retrying in \(delay)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // All attempts failed - show error
        self.error = AppError.network(lastError ?? NSError(domain: "TVShowDetailViewModel", code: -1))
        isLoading = false
    }

    private func attemptLoadTVShowDetails() async throws {
        async let tvShowTask = tmdbService.getTVShowDetails(id: tvShowId)
        async let creditsTask = tmdbService.getTVShowCredits(id: tvShowId)
        async let videosTask = tmdbService.getTVShowVideos(id: tvShowId)
        async let providersTask = tmdbService.getTVShowWatchProviders(id: tvShowId)
        async let similarTask = tmdbService.getSimilarTVShows(id: tvShowId, page: 1)
        async let externalIdsTask = tmdbService.getTVShowExternalIds(id: tvShowId)

        let (tvShowData, creditsData, videosData, providersData, similarData, externalIdsData) = try await (
            tvShowTask, creditsTask, videosTask, providersTask, similarTask, externalIdsTask
        )

        tvShow = tvShowData
        credits = creditsData
        videos = videosData.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
        imdbId = externalIdsData.imdbId

        // Use current country for watch providers
        let country = LocalizationManager.shared.currentCountry.id
        let baseProviders = providersData.results[country]

        similarShows = Array(similarData.results.prefix(10))

        print("📺 [TVShowDetail] IMDB ID: \(imdbId ?? "nil")")
        print("🔗 [TVShowDetail] JustWatch Link: \(baseProviders?.link ?? "nil")")

        // Fetch streaming availability pricing and quality data (non-blocking)
        // Always set watchProviders first to prevent errors
        watchProviders = baseProviders

        do {
            let watchmodeSources = try await watchmodeService.getStreamingSources(
                tmdbId: tvShowId,
                type: .tv,
                region: country
            )

            print("✅ [Watchmode] Fetched \(watchmodeSources.count) sources for TV show")

            // Merge Watchmode data with TMDb providers
            if var providers = baseProviders {
                providers = mergeWatchmodeData(providers: providers, sources: watchmodeSources)
                watchProviders = providers
            }
        } catch {
            print("⚠️ [Watchmode] Failed to fetch pricing data: \(error.localizedDescription)")
            // Already set watchProviders above, so we're good
        }

        // Debug: Print provider information including price and quality
        if let providers = watchProviders {
            if let flatrate = providers.flatrate {
                print("📺 [TVShowDetail] Streaming Providers: \(flatrate.count)")
                flatrate.forEach { provider in
                    print("   - \(provider.providerName) | Price: \(provider.price?.displayPrice ?? "nil") | Quality: \(provider.formattedQuality ?? "nil")")
                }
            }
            if let rent = providers.rent {
                print("💰 [TVShowDetail] Rent Providers: \(rent.count)")
                rent.forEach { provider in
                    print("   - \(provider.providerName) | Price: \(provider.price?.displayPrice ?? "nil") | Quality: \(provider.formattedQuality ?? "nil")")
                }
            }
            if let buy = providers.buy {
                print("🛒 [TVShowDetail] Buy Providers: \(buy.count)")
                buy.forEach { provider in
                    print("   - \(provider.providerName) | Price: \(provider.price?.displayPrice ?? "nil") | Quality: \(provider.formattedQuality ?? "nil")")
                }
            }
        }
    }
    
    var mainCast: [Cast] {
        Array(credits?.cast.prefix(10) ?? [])
    }
    
    var trailer: Video? {
        videos.first
    }
    
    // MARK: - Helper Methods
    
    /// Merge Watchmode pricing/quality data with TMDb providers
    private func mergeWatchmodeData(providers: CountryProviders, sources: [WatchmodeSource]) -> CountryProviders {
        var updatedProviders = providers
        
        // Update streaming providers
        if let flatrate = providers.flatrate {
            updatedProviders.flatrate = flatrate.map { provider in
                enrichProvider(provider, with: sources, type: "sub")
            }
        }
        
        // Update rent providers
        if let rent = providers.rent {
            updatedProviders.rent = rent.map { provider in
                enrichProvider(provider, with: sources, type: "rent")
            }
        }
        
        // Update buy providers
        if let buy = providers.buy {
            updatedProviders.buy = buy.map { provider in
                enrichProvider(provider, with: sources, type: "buy")
            }
        }
        
        return updatedProviders
    }
    
    /// Enrich a provider with Watchmode data
    private func enrichProvider(_ provider: Provider, with sources: [WatchmodeSource], type: String) -> Provider {
        // Try to find matching Watchmode source by name
        guard let matchingSource = sources.first(where: { source in
            source.type == type && providerNamesMatch(provider.providerName, source.name)
        }) else {
            // Debug: Print why this provider didn't match
            let availableNames = sources.filter { $0.type == type }.map { $0.name }.joined(separator: ", ")
            print("   ⚠️ No match for '\(provider.providerName)' (type: \(type)). Available: [\(availableNames)]")
            return provider
        }
        
        // Create price info if available
        var priceInfo: PriceInfo? = nil
        if let price = matchingSource.price, let currency = matchingSource.currency {
            priceInfo = PriceInfo(
                value: price,
                currency: currency,
                formatted: matchingSource.formattedPrice
            )
        }
        
        // Create enriched provider with pricing and quality
        return Provider(
            providerId: provider.providerId,
            providerName: provider.providerName,
            logoPath: provider.logoPath,
            displayPriority: provider.displayPriority,
            price: priceInfo,
            quality: matchingSource.format,
            presentationType: provider.presentationType
        )
    }
    
    /// Check if provider names match (fuzzy matching with aliases)
    private func providerNamesMatch(_ tmdbName: String, _ watchmodeName: String) -> Bool {
        // Normalize both names
        let normalized1 = normalizeProviderName(tmdbName)
        let normalized2 = normalizeProviderName(watchmodeName)
        
        // Direct match
        if normalized1 == normalized2 {
            return true
        }
        
        // Substring match
        if normalized1.contains(normalized2) || normalized2.contains(normalized1) {
            return true
        }
        
        // Check known aliases
        if areKnownAliases(normalized1, normalized2) {
            return true
        }
        
        return false
    }
    
    /// Normalize provider name for comparison
    private func normalizeProviderName(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "+", with: "plus")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "tv", with: "")
            .replacingOccurrences(of: "video", with: "")
    }
    
    /// Check if two names are known aliases
    private func areKnownAliases(_ name1: String, _ name2: String) -> Bool {
        let aliasGroups: [[String]] = [
            ["amazon", "prime", "primevideo", "amazonvideo"],
            ["apple", "appletv", "appletvplus"],
            ["paramount", "paramountplus"],
            ["hbo", "hbomax", "max"],
            ["disney", "disneyplus"],
            ["google", "googleplay", "googleplaymovies"],
            ["rakuten", "rakutentv"],
            ["chili"],
            ["timvision"],
            ["mediaset", "mediasetinfinity"],
            ["netflix"],
            ["hulu"]
        ]
        
        for group in aliasGroups {
            if group.contains(where: { name1.contains($0) }) &&
               group.contains(where: { name2.contains($0) }) {
                return true
            }
        }
        
        return false
    }
}
