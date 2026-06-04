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

    private let showId: Int
    private let seasonNumber: Int
    private let tmdb: any TVSeasonProviding
    private let cache: any TVSeasonCaching

    init(
        showId: Int,
        seasonNumber: Int,
        tmdb: any TVSeasonProviding = TMDBService.shared,
        cache: any TVSeasonCaching = DetailCacheService.shared
    ) {
        self.showId = showId
        self.seasonNumber = seasonNumber
        self.tmdb = tmdb
        self.cache = cache
    }

    func loadSeasonDetails() async {
        isLoading = true
        error = nil

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
}
