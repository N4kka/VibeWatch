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
    @Published var whyForMeMessage: String?
    @Published var isWhyForMeLoading = false
    @Published var whyForMeError: String?
    
    private let tmdbService = TMDBService.shared
    private let streamingService = StreamingAvailabilityService.shared
    private let detailCache = DetailCacheService.shared
    private let quotaService = ClipQuotaService.shared
    private let cerebrasService = CerebrasService.shared
    private let preferenceManager = UserPreferenceManager.shared
    private let aiTokenManager = AITokenManager.shared
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
        async let similarTask = tmdbService.getSimilarMovies(id: movieId, page: 1)
        async let externalIdsTask = tmdbService.getMovieExternalIds(id: movieId)
        // Fetch TMDB providers too for merging
        async let tmdbProvidersTask = tmdbService.getMovieWatchProviders(id: movieId)

        let (movieData, creditsData, videosData, similarData, externalIdsData, tmdbProvidersData) = try await (
            movieTask, creditsTask, videosTask, similarTask, externalIdsTask, tmdbProvidersTask
        )

        movie = movieData
        credits = creditsData
        videos = videosData.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
        imdbId = externalIdsData.imdbId
        similarMovies = Array(similarData.results.prefix(10))

        print("🎬 [MovieDetail] IMDB ID: \(imdbId ?? "nil")")

        // Streaming Availability Logic
        let country = LocalizationManager.shared.currentCountry.id
        let tmdbProviders = tmdbProvidersData.results[country]
        
        do {
            // 1. Fetch rich data from RapidAPI
            var richProviders = try await streamingService.getProviders(
                tmdbId: movieId,
                type: .movie,
                region: country
            )
            print("✅ [StreamingAvailability] Loaded comprehensive providers")
            
            // 2. Merge with TMDB data (to fill gaps like Rakuten, Google Play if missing)
            if let tmdb = tmdbProviders {
                richProviders = mergeProviders(rich: richProviders, basic: tmdb)
            }
            
            self.watchProviders = richProviders
        } catch {
            print("⚠️ [StreamingAvailability] API failed: \(error.localizedDescription). Falling back to TMDB.")
            self.watchProviders = tmdbProviders
        }
    }
    
    private func mergeProviders(rich: CountryProviders, basic: CountryProviders) -> CountryProviders {
        var merged = rich
        
        // Helper to merge a specific list type (flatrate, rent, buy)
        func mergeList(_ richList: [Provider]?, _ basicList: [Provider]?) -> [Provider]? {
            guard let basicList = basicList else { return richList }
            guard var richList = richList else { return basicList }
            
            for provider in basicList {
                // Check if provider is already in rich list (fuzzy match name)
                if let index = richList.firstIndex(where: { providerNamesMatch($0.providerName, provider.providerName) }) {
                    // It exists. Check if rich provider has a valid logo.
                    // RapidAPI logos are full URLs, TMDB are paths.
                    // If RapidAPI logo is missing or empty, try to use TMDB logo path.
                    // Note: Our Provider struct handles full URLs in logoPath logic, so we can just swap the string.
                    let richLogo = richList[index].logoPath.lowercased()
                    let shouldPreferTMDBLogo = richLogo.isEmpty || richLogo.contains(".svg")
                    if shouldPreferTMDBLogo && !provider.logoPath.isEmpty {
                        print("   ♻️ Using TMDB logo for \(richList[index].providerName)")
                        // We need to create a new provider because it's a struct (value type)
                        let existing = richList[index]
                        richList[index] = Provider(
                            providerId: existing.providerId,
                            providerName: existing.providerName,
                            logoPath: provider.logoPath, // Use TMDB logo path
                            displayPriority: existing.displayPriority,
                            price: existing.price,
                            quality: existing.quality,
                            presentationType: existing.presentationType,
                            externalLink: existing.externalLink
                        )
                    }
                } else {
                    // If provider is NOT in rich list, add it
                    print("   ➕ Merging missing provider from TMDB: \(provider.providerName)")
                    richList.append(provider)
                }
            }
            return richList
        }
        
        merged.flatrate = mergeList(rich.flatrate, basic.flatrate)
        merged.rent = mergeList(rich.rent, basic.rent)
        merged.buy = mergeList(rich.buy, basic.buy)
        merged.link = rich.link ?? basic.link // Prefer rich link, fallback to JustWatch
        
        return merged
    }
    
    private func providerNamesMatch(_ name1: String, _ name2: String) -> Bool {
        let n1 = normalize(name1)
        let n2 = normalize(name2)
        return n1 == n2 || n1.contains(n2) || n2.contains(n1)
    }
    
    private func normalize(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "+", with: "plus")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "tv", with: "")
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

    func generateWhyForMe() async {
        guard let movie else { return }
        guard !isWhyForMeLoading else { return }

        isWhyForMeLoading = true
        whyForMeError = nil

        let profile = await preferenceManager.aggregatePreferences()
        let language = LocalizationManager.shared.currentLanguage
        let details = buildMovieDetails(movie: movie, credits: credits)

        do {
            let response = try await cerebrasService.generateWhyForMe(
                movie: details,
                userProfile: profile,
                languageName: language.nativeName,
                languageCode: language.id
            )
            if isInvalidWhyForMe(response) {
                whyForMeMessage = nil
                whyForMeError = "common.error".localized
            } else {
                whyForMeMessage = response
            }
            aiTokenManager.recordUsage()
        } catch {
            whyForMeError = error.localizedDescription
        }

        isWhyForMeLoading = false
    }
    
    // MARK: - Helper Methods

    private func buildMovieDetails(movie: Movie, credits: Credits?) -> MovieDetails {
        let mappedGenres = movie.genres?.map { MovieDetails.Genre(id: $0.id, name: $0.name) }
        let mappedCast = credits?.cast.prefix(6).map {
            MovieDetails.CastMember(id: $0.id, name: $0.name, character: $0.character)
        }
        let mappedCrew = credits?.crew.prefix(6).map {
            MovieDetails.CrewMember(id: $0.id, name: $0.name, job: $0.job)
        }

        let mappedCredits: MovieDetails.Credits?
        if mappedCast != nil || mappedCrew != nil {
            mappedCredits = MovieDetails.Credits(cast: mappedCast, crew: mappedCrew)
        } else {
            mappedCredits = nil
        }

        return MovieDetails(
            id: movie.id,
            title: movie.title,
            overview: movie.overview,
            releaseDate: movie.releaseDate,
            voteAverage: movie.voteAverage,
            voteCount: movie.voteCount,
            runtime: movie.runtime,
            genres: mappedGenres,
            credits: mappedCredits
        )
    }

    private func isInvalidWhyForMe(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "..." || trimmed == "…" { return true }
        if trimmed.count < 10 { return true }
        let lower = trimmed.lowercased()
        if lower.contains("analysis") || lower.contains("analyze") { return true }
        if lower.contains("top genres") || lower.contains("genres:") { return true }
        if lower.contains("cast:") || lower.contains("overview") { return true }
        if trimmed.contains("**") { return true }
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
    @Published var whyForMeMessage: String?
    @Published var isWhyForMeLoading = false
    @Published var whyForMeError: String?
    
    private let tmdbService = TMDBService.shared
    private let streamingService = StreamingAvailabilityService.shared
    private let detailCache = DetailCacheService.shared
    private let quotaService = ClipQuotaService.shared
    private let cerebrasService = CerebrasService.shared
    private let preferenceManager = UserPreferenceManager.shared
    private let aiTokenManager = AITokenManager.shared
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
        async let similarTask = tmdbService.getSimilarTVShows(id: tvShowId, page: 1)
        async let externalIdsTask = tmdbService.getTVShowExternalIds(id: tvShowId)
        async let tmdbProvidersTask = tmdbService.getTVShowWatchProviders(id: tvShowId)

        let (tvShowData, creditsData, videosData, similarData, externalIdsData, tmdbProvidersData) = try await (
            tvShowTask, creditsTask, videosTask, similarTask, externalIdsTask, tmdbProvidersTask
        )

        tvShow = tvShowData
        credits = creditsData
        videos = videosData.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
        imdbId = externalIdsData.imdbId
        similarShows = Array(similarData.results.prefix(10))

        print("📺 [TVShowDetail] IMDB ID: \(imdbId ?? "nil")")

        // Streaming Availability Logic
        let country = LocalizationManager.shared.currentCountry.id
        let tmdbProviders = tmdbProvidersData.results[country]
        
        do {
            // 1. Fetch rich data from RapidAPI
            var richProviders = try await streamingService.getProviders(
                tmdbId: tvShowId,
                type: .tv,
                region: country
            )
            print("✅ [StreamingAvailability] Loaded comprehensive providers for TV Show")
            
            // 2. Merge with TMDB data
            if let tmdb = tmdbProviders {
                richProviders = mergeProviders(rich: richProviders, basic: tmdb)
            }
            
            self.watchProviders = richProviders
        } catch {
            print("⚠️ [StreamingAvailability] API failed: \(error.localizedDescription). Falling back to TMDB.")
            self.watchProviders = tmdbProviders
        }
    }
    
    private func mergeProviders(rich: CountryProviders, basic: CountryProviders) -> CountryProviders {
        var merged = rich
        
        func mergeList(_ richList: [Provider]?, _ basicList: [Provider]?) -> [Provider]? {
            guard let basicList = basicList else { return richList }
            guard var richList = richList else { return basicList }
            
            for provider in basicList {
                // Check if provider is already in rich list (fuzzy match name)
                if let index = richList.firstIndex(where: { providerNamesMatch($0.providerName, provider.providerName) }) {
                    // It exists. Check if rich provider has a valid logo.
                    let richLogo = richList[index].logoPath.lowercased()
                    let shouldPreferTMDBLogo = richLogo.isEmpty || richLogo.contains(".svg")
                    if shouldPreferTMDBLogo && !provider.logoPath.isEmpty {
                        print("   ♻️ Using TMDB logo for \(richList[index].providerName)")
                        let existing = richList[index]
                        richList[index] = Provider(
                            providerId: existing.providerId,
                            providerName: existing.providerName,
                            logoPath: provider.logoPath, // Use TMDB logo path
                            displayPriority: existing.displayPriority,
                            price: existing.price,
                            quality: existing.quality,
                            presentationType: existing.presentationType,
                            externalLink: existing.externalLink
                        )
                    }
                } else {
                    // If provider is NOT in rich list, add it
                    print("   ➕ Merging missing provider from TMDB: \(provider.providerName)")
                    richList.append(provider)
                }
            }
            return richList
        }
        
        merged.flatrate = mergeList(rich.flatrate, basic.flatrate)
        merged.rent = mergeList(rich.rent, basic.rent)
        merged.buy = mergeList(rich.buy, basic.buy)
        merged.link = rich.link ?? basic.link
        
        return merged
    }
    
    private func providerNamesMatch(_ name1: String, _ name2: String) -> Bool {
        let n1 = normalize(name1)
        let n2 = normalize(name2)
        return n1 == n2 || n1.contains(n2) || n2.contains(n1)
    }
    
    private func normalize(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "+", with: "plus")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "tv", with: "")
    }
    
    var mainCast: [Cast] {
        Array(credits?.cast.prefix(10) ?? [])
    }
    
    var trailer: Video? {
        videos.first
    }

    func generateWhyForMe() async {
        guard let tvShow else { return }
        guard !isWhyForMeLoading else { return }

        isWhyForMeLoading = true
        whyForMeError = nil

        let profile = await preferenceManager.aggregatePreferences()
        let language = LocalizationManager.shared.currentLanguage
        let details = buildMovieDetails(tvShow: tvShow, credits: credits)

        do {
            let response = try await cerebrasService.generateWhyForMe(
                movie: details,
                userProfile: profile,
                languageName: language.nativeName,
                languageCode: language.id
            )
            if isInvalidWhyForMe(response) {
                whyForMeMessage = nil
                whyForMeError = "common.error".localized
            } else {
                whyForMeMessage = response
            }
            aiTokenManager.recordUsage()
        } catch {
            whyForMeError = error.localizedDescription
        }

        isWhyForMeLoading = false
    }
    
    // MARK: - Helper Methods

    private func buildMovieDetails(tvShow: TVShow, credits: Credits?) -> MovieDetails {
        let mappedGenres = tvShow.genres?.map { MovieDetails.Genre(id: $0.id, name: $0.name) }
        let mappedCast = credits?.cast.prefix(6).map {
            MovieDetails.CastMember(id: $0.id, name: $0.name, character: $0.character)
        }
        let mappedCrew = credits?.crew.prefix(6).map {
            MovieDetails.CrewMember(id: $0.id, name: $0.name, job: $0.job)
        }

        let mappedCredits: MovieDetails.Credits?
        if mappedCast != nil || mappedCrew != nil {
            mappedCredits = MovieDetails.Credits(cast: mappedCast, crew: mappedCrew)
        } else {
            mappedCredits = nil
        }

        return MovieDetails(
            id: tvShow.id,
            title: tvShow.name,
            overview: tvShow.overview,
            releaseDate: tvShow.firstAirDate,
            voteAverage: tvShow.voteAverage,
            voteCount: tvShow.voteCount,
            runtime: nil,
            genres: mappedGenres,
            credits: mappedCredits
        )
    }

    private func isInvalidWhyForMe(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "..." || trimmed == "…" { return true }
        if trimmed.count < 10 { return true }
        return false
    }
}
