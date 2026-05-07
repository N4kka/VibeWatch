import Foundation

enum WatchProviderLoadState {
    case loading
    case available(CountryProviders)
    case unavailable

    var providers: CountryProviders? {
        if case .available(let providers) = self { return providers }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

@MainActor
class MovieDetailViewModel: ObservableObject {
    @Published var movie: Movie?
    @Published var credits: Credits?
    @Published var videos: [Video] = []
    @Published var watchProviders: CountryProviders?
    @Published var watchProviderState: WatchProviderLoadState = .loading
    @Published var similarMovies: [Movie] = []
    @Published var imdbId: String?
    @Published var isLoading = false
    @Published var error: AppError?
    @Published var whyForMeMessage: String?
    @Published var isWhyForMeLoading = false
    @Published var whyForMeError: String?
    
    private let mediaDetailRepository: any MediaDetailRepositoryProtocol
    private let providersRepository: any WatchProvidersRepositoryProtocol
    private let cerebrasService: CerebrasService
    private let preferenceManager: UserPreferenceManager
    private let aiTokenManager: AITokenManager
    private let movieId: Int

    init(
        movieId: Int,
        mediaDetailRepository: any MediaDetailRepositoryProtocol = LiveMediaDetailRepository.shared,
        providersRepository: any WatchProvidersRepositoryProtocol = LiveWatchProvidersRepository.shared,
        cerebrasService: CerebrasService = .shared,
        preferenceManager: UserPreferenceManager = .shared,
        aiTokenManager: AITokenManager = .shared
    ) {
        self.movieId = movieId
        self.mediaDetailRepository = mediaDetailRepository
        self.providersRepository = providersRepository
        self.cerebrasService = cerebrasService
        self.preferenceManager = preferenceManager
        self.aiTokenManager = aiTokenManager
    }

    func loadMovieDetails() async {
        isLoading = true
        error = nil
        watchProviders = nil
        watchProviderState = .loading
        let region = LocalizationManager.shared.currentCountry.id

        // Stream 1: cache-first detail (instant on cache hit, background refresh after)
        // Stream 2: providers with 24h TTL (concurrent)
        Task(priority: .utility) {
            for await providers in self.providersRepository.observeProviders(
                mediaId: self.movieId, mediaType: .movie, region: region
            ) {
                if let providers, providers.hasUsableProviders {
                    self.watchProviders = providers
                    self.watchProviderState = .available(providers)
                } else {
                    self.watchProviders = nil
                    self.watchProviderState = .unavailable
                }
            }
        }

        for await snapshot in mediaDetailRepository.observeMovie(id: movieId) {
            self.movie = snapshot.movie
            self.credits = snapshot.credits
            self.videos = snapshot.videos
            self.similarMovies = snapshot.similarMovies
            self.imdbId = snapshot.movie.imdbId
            self.isLoading = false
            self.error = nil
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
    @Published var watchProviderState: WatchProviderLoadState = .loading
    @Published var similarShows: [TVShow] = []
    @Published var imdbId: String?
    @Published var isLoading = false
    @Published var error: AppError?
    @Published var whyForMeMessage: String?
    @Published var isWhyForMeLoading = false
    @Published var whyForMeError: String?
    
    private let mediaDetailRepository: any MediaDetailRepositoryProtocol
    private let providersRepository: any WatchProvidersRepositoryProtocol
    private let cerebrasService: CerebrasService
    private let preferenceManager: UserPreferenceManager
    private let aiTokenManager: AITokenManager
    private let tvShowId: Int

    init(
        tvShowId: Int,
        mediaDetailRepository: any MediaDetailRepositoryProtocol = LiveMediaDetailRepository.shared,
        providersRepository: any WatchProvidersRepositoryProtocol = LiveWatchProvidersRepository.shared,
        cerebrasService: CerebrasService = .shared,
        preferenceManager: UserPreferenceManager = .shared,
        aiTokenManager: AITokenManager = .shared
    ) {
        self.tvShowId = tvShowId
        self.mediaDetailRepository = mediaDetailRepository
        self.providersRepository = providersRepository
        self.cerebrasService = cerebrasService
        self.preferenceManager = preferenceManager
        self.aiTokenManager = aiTokenManager
    }

    func loadTVShowDetails() async {
        isLoading = true
        error = nil
        watchProviders = nil
        watchProviderState = .loading
        let region = LocalizationManager.shared.currentCountry.id

        Task(priority: .utility) {
            for await providers in self.providersRepository.observeProviders(
                mediaId: self.tvShowId, mediaType: .tv, region: region
            ) {
                if let providers, providers.hasUsableProviders {
                    self.watchProviders = providers
                    self.watchProviderState = .available(providers)
                } else {
                    self.watchProviders = nil
                    self.watchProviderState = .unavailable
                }
            }
        }

        for await snapshot in mediaDetailRepository.observeTVShow(id: tvShowId) {
            self.tvShow = snapshot.tvShow
            self.credits = snapshot.credits
            self.videos = snapshot.videos
            self.similarShows = snapshot.similarShows
            self.imdbId = snapshot.tvShow.imdbId
            self.isLoading = false
            self.error = nil
        }
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
