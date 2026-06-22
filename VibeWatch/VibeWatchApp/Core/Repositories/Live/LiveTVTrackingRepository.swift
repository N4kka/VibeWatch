import Foundation

@MainActor
final class LiveTVTrackingRepository: TVTrackingRepositoryProtocol {
    static let shared = LiveTVTrackingRepository()
    private init() {}

    func fetchBuckets() async -> TVTrackingBuckets {
        let allLists = ListManager.shared.lists
        let seenManager = EpisodeSeenManager.shared

        // Serie nella lista core "seen": trattate come "in pari" anche senza tracking episodi
        // (unifica checkmark/lista seen con il tracking, copre anche i dati storici).
        var seenListShowIds = Set<Int>()
        for list in allLists where list.type == .seen {
            for item in list.items where item.mediaType == .tv {
                seenListShowIds.insert(item.mediaId)
            }
        }

        // Sorgenti: tutte le liste TRANNE "disliked". Dedup per mediaId.
        var uniqueTVShows: [Int: MediaListItem] = [:]
        for list in allLists where list.type != .disliked {
            for item in list.items where item.mediaType == .tv {
                uniqueTVShows[item.mediaId] = item
            }
        }

        var buckets = TVTrackingBuckets()
        // Serie a progresso PARZIALE: servono i dettagli TMDB (numberOfEpisodes) per decidere
        // continua-a-guardare vs in-pari. Tutto il resto si classifica SENZA rete → la tab
        // "Da iniziare" non dipende più da TMDB (fix del bug "non appare nulla").
        var partial: [(item: MediaListItem, seenCount: Int)] = []

        for (showId, item) in uniqueTVShows {
            let isFullySeen = seenManager.seenShowIds.contains(showId) || seenListShowIds.contains(showId)
            if isFullySeen {
                buckets.upToDate.append(item)
                continue
            }
            let seenCount = seenManager.seenKeys.filter { $0.hasPrefix("\(showId)_") }.count
            if seenCount == 0 {
                buckets.notStarted.append(item)
            } else {
                partial.append((item, seenCount))
            }
        }

        // Solo per le (poche) serie a progresso parziale interroghiamo TMDB, con timeout per
        // non bloccare la UI: se la rete è lenta la serie resta "Continua a guardare" (default sicuro).
        if !partial.isEmpty {
            await withTaskGroup(of: (MediaListItem, Bool).self) { group in
                for entry in partial {
                    group.addTask {
                        let total = await Self.tvDetailsWithTimeout(id: entry.item.mediaId)?.numberOfEpisodes ?? 0
                        let caughtUp = total > 0 && entry.seenCount >= total
                        return (entry.item, caughtUp)
                    }
                }
                for await (item, caughtUp) in group {
                    if caughtUp { buckets.upToDate.append(item) } else { buckets.continuing.append(item) }
                }
            }
        }

        buckets.continuing.sort { $0.title < $1.title }
        buckets.notStarted.sort { $0.title < $1.title }
        buckets.upToDate.sort { $0.title < $1.title }

        return buckets
    }

    /// `getTVShowDetails` con timeout: evita che una chiamata in hang blocchi il calcolo dei bucket.
    private static func tvDetailsWithTimeout(id: Int, seconds: Double = 8) async -> TVShow? {
        await withTaskGroup(of: TVShow?.self) { group in
            group.addTask { try? await TMDBService.shared.getTVShowDetails(id: id) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
