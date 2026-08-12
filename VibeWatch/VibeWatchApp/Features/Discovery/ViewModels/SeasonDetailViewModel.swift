import Foundation

// MARK: - Narrow dependency seams (DI proof-of-pattern, Fase 5)
//
// Invece di iniettare l'intero TMDBServiceProtocol / DetailCacheService, il VM dipende da
// due protocolli STRETTI (interface segregation) con i soli metodi che usa. Questo rende i
// fake banali nei test e disaccoppia il VM dai singleton concreti. I default `.shared`
// preservano il comportamento di produzione (call-site invariata).

protocol TVSeasonProviding {
    func getTVSeasonDetails(showId: Int, seasonNumber: Int) async throws -> SeasonDetail
}

protocol TVSeasonCaching {
    func getCachedTVSeason(showId: Int, seasonNumber: Int) async throws -> SeasonDetail?
    func cacheTVSeason(_ season: SeasonDetail, showId: Int, seasonNumber: Int) async throws
}

// TMDBService conforma a TVSeasonProviding via TMDBServiceProtocol (che lo rifina).
extension DetailCacheService: TVSeasonCaching {}

@MainActor
class SeasonDetailViewModel: ObservableObject {
    @Published var season: SeasonDetail?
    @Published var isLoading = false
    @Published var error: AppError?

    /// Gli episodi di questa stagione con almeno un `watch_event` nello specchio locale.
    /// EpisodeSeenManager (UserDefaults) conosce solo i tap fatti in QUESTA schermata: i
    /// "visto" dal Tracking, l'import TV Time e gli altri device vivono in `watch_events` —
    /// senza questa lettura la lista episodi li ignorava e sembrava disallineata.
    @Published private(set) var watchedEpisodeNumbers: Set<Int> = []

    private let showId: Int
    private let seasonNumber: Int
    private let tmdb: any TVSeasonProviding
    private let cache: any TVSeasonCaching
    private let watchedEvents: (Int, Int) async -> Set<Int>

    init(
        showId: Int,
        seasonNumber: Int,
        tmdb: any TVSeasonProviding = TMDBService.shared,
        cache: any TVSeasonCaching = DetailCacheService.shared,
        watchedEvents: ((Int, Int) async -> Set<Int>)? = nil
    ) {
        self.showId = showId
        self.seasonNumber = seasonNumber
        self.tmdb = tmdb
        self.cache = cache
        self.watchedEvents = watchedEvents ?? { showId, seasonNumber in
            let rows = (try? await SQLiteService.shared.queryRaw(
                """
                SELECT DISTINCT episode_number FROM watch_events
                WHERE tmdb_show_id = ? AND season_number = ?
                  AND media_type = 'tv' AND deleted_at IS NULL
                """,
                parameters: [showId, seasonNumber]
            )) ?? []
            return Set(rows.compactMap { row in
                (row["episode_number"] as? Int)
                    ?? (row["episode_number"] as? Int64).map(Int.init)
            })
        }
    }

    func loadSeasonDetails() async {
        isLoading = true
        error = nil

        await refreshWatchedEvents()

        if let cached = try? await cache.getCachedTVSeason(showId: showId, seasonNumber: seasonNumber) {
            season = cached
            isLoading = false
            Task(priority: .utility) {
                guard let fresh = try? await self.tmdb.getTVSeasonDetails(showId: self.showId, seasonNumber: self.seasonNumber) else { return }
                try? await self.cache.cacheTVSeason(fresh, showId: self.showId, seasonNumber: self.seasonNumber)
                self.season = fresh
            }
            return
        }

        do {
            let fresh = try await tmdb.getTVSeasonDetails(showId: showId, seasonNumber: seasonNumber)
            try? await cache.cacheTVSeason(fresh, showId: showId, seasonNumber: seasonNumber)
            season = fresh
        } catch {
            self.error = error as? AppError ?? .unknown(error)
        }
        isLoading = false
    }

    /// Rilegge lo specchio locale. La chiama `loadSeasonDetails` e la view al
    /// `syncCompletedNotification`: un "visto" dal Tracking arriva qui via pull.
    func refreshWatchedEvents() async {
        watchedEpisodeNumbers = await watchedEvents(showId, seasonNumber)
    }
}
