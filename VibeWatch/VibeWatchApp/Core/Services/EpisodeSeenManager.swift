import Foundation

@MainActor
final class EpisodeSeenManager: ObservableObject {
    static let shared = EpisodeSeenManager()

    // Individual episode keys: "showId_season_episode"
    @Published private(set) var seenKeys: Set<String> = []
    // Whole-show seen flag (set when user marks all episodes via the show detail confirmation)
    @Published private(set) var seenShowIds: Set<Int> = []

    private let episodesDefaultsKey = "vibewatch.seen_episodes"
    private let showsDefaultsKey = "vibewatch.seen_shows"

    private init() {
        let storedEpisodes = UserDefaults.standard.stringArray(forKey: episodesDefaultsKey) ?? []
        seenKeys = Set(storedEpisodes)
        let storedShows = UserDefaults.standard.array(forKey: showsDefaultsKey) as? [Int] ?? []
        seenShowIds = Set(storedShows)
    }

    // MARK: - Queries

    func isEpisodeSeen(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Bool {
        seenShowIds.contains(showId) ||
        seenKeys.contains(makeKey(showId: showId, season: seasonNumber, episode: episodeNumber))
    }

    func isSeasonFullySeen(showId: Int, seasonNumber: Int, episodes: [Episode]) -> Bool {
        guard !episodes.isEmpty else { return false }
        if seenShowIds.contains(showId) { return true }
        return episodes.allSatisfy { isEpisodeSeen(showId: showId, seasonNumber: seasonNumber, episodeNumber: $0.episodeNumber) }
    }

    // MARK: - Whole-show

    func markShowSeen(showId: Int) {
        seenShowIds.insert(showId)
        persistShows()
    }

    func unmarkShowSeen(showId: Int) {
        seenShowIds.remove(showId)
        persistShows()
    }

    // MARK: - Season-level

    func markSeasonSeen(showId: Int, seasonNumber: Int, episodes: [Episode]) {
        for ep in episodes {
            seenKeys.insert(makeKey(showId: showId, season: seasonNumber, episode: ep.episodeNumber))
        }
        persistEpisodes()
    }

    func unmarkSeasonSeen(showId: Int, seasonNumber: Int, episodes: [Episode]) {
        // If the whole show was marked seen, clear that flag so we're back to episode-level tracking
        if seenShowIds.contains(showId) {
            seenShowIds.remove(showId)
            persistShows()
        }
        for ep in episodes {
            seenKeys.remove(makeKey(showId: showId, season: seasonNumber, episode: ep.episodeNumber))
        }
        persistEpisodes()
    }

    // MARK: - Episode-level

    func toggleEpisode(showId: Int, seasonNumber: Int, episodeNumber: Int, allEpisodesInSeason: [Episode]) {
        let k = makeKey(showId: showId, season: seasonNumber, episode: episodeNumber)
        let currentlySeen = isEpisodeSeen(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)

        if currentlySeen {
            // Toggling off: if the whole show was flagged seen, expand to individual episode keys
            // for this season then remove this one. Other seasons stay "unseen" (no keys exist for them).
            if seenShowIds.contains(showId) {
                seenShowIds.remove(showId)
                persistShows()
                // Mark all other episodes in this season as individually seen
                for ep in allEpisodesInSeason where ep.episodeNumber != episodeNumber {
                    seenKeys.insert(makeKey(showId: showId, season: seasonNumber, episode: ep.episodeNumber))
                }
            }
            seenKeys.remove(k)
        } else {
            seenKeys.insert(k)
        }
        persistEpisodes()
    }

    // MARK: - Private

    private func makeKey(showId: Int, season: Int, episode: Int) -> String {
        "\(showId)_\(season)_\(episode)"
    }

    private func persistEpisodes() {
        UserDefaults.standard.set(Array(seenKeys), forKey: episodesDefaultsKey)
    }

    private func persistShows() {
        UserDefaults.standard.set(Array(seenShowIds), forKey: showsDefaultsKey)
    }
}
