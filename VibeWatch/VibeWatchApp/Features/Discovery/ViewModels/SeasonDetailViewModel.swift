import Foundation

@MainActor
class SeasonDetailViewModel: ObservableObject {
    @Published var season: SeasonDetail?
    @Published var isLoading = false
    @Published var error: AppError?

    private let showId: Int
    private let seasonNumber: Int

    init(showId: Int, seasonNumber: Int) {
        self.showId = showId
        self.seasonNumber = seasonNumber
    }

    func loadSeasonDetails() async {
        isLoading = true
        error = nil

        if let cached = try? await DetailCacheService.shared.getCachedTVSeason(showId: showId, seasonNumber: seasonNumber) {
            season = cached
            isLoading = false
            Task(priority: .utility) {
                guard let fresh = try? await TMDBService.shared.getTVSeasonDetails(showId: self.showId, seasonNumber: self.seasonNumber) else { return }
                try? await DetailCacheService.shared.cacheTVSeason(fresh, showId: self.showId, seasonNumber: self.seasonNumber)
                self.season = fresh
            }
            return
        }

        do {
            let fresh = try await TMDBService.shared.getTVSeasonDetails(showId: showId, seasonNumber: seasonNumber)
            try? await DetailCacheService.shared.cacheTVSeason(fresh, showId: showId, seasonNumber: seasonNumber)
            season = fresh
        } catch {
            self.error = error as? AppError ?? .unknown(error)
        }
        isLoading = false
    }
}
