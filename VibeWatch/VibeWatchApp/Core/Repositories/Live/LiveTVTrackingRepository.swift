import Foundation

@MainActor
final class LiveTVTrackingRepository: TVTrackingRepositoryProtocol {
    static let shared = LiveTVTrackingRepository()
    private init() {}

    func fetchBuckets() async -> TVTrackingBuckets {
        let allLists = ListManager.shared.lists
        var uniqueTVShows: [Int: MediaListItem] = [:]
        
        for list in allLists {
            for item in list.items where item.mediaType == .tv {
                uniqueTVShows[item.mediaId] = item
            }
        }
        
        var buckets = TVTrackingBuckets()
        let seenManager = EpisodeSeenManager.shared
        
        await withTaskGroup(of: (MediaListItem, TVShow?).self) { group in
            for (_, item) in uniqueTVShows {
                group.addTask {
                    let details = try? await TMDBService.shared.getTVShowDetails(id: item.mediaId)
                    return (item, details)
                }
            }
            
            for await (item, details) in group {
                let showId = item.mediaId
                let isFullyMarked = seenManager.seenShowIds.contains(showId)
                let prefix = "\(showId)_"
                let seenEpisodesCount = seenManager.seenKeys.filter { $0.hasPrefix(prefix) }.count
                let totalEpisodes = details?.numberOfEpisodes ?? 0
                
                if isFullyMarked {
                    buckets.upToDate.append(item)
                } else if seenEpisodesCount == 0 {
                    buckets.notStarted.append(item)
                } else if totalEpisodes > 0 && seenEpisodesCount >= totalEpisodes {
                    buckets.upToDate.append(item)
                } else {
                    buckets.continuing.append(item)
                }
            }
        }
        
        buckets.continuing.sort { $0.title < $1.title }
        buckets.notStarted.sort { $0.title < $1.title }
        buckets.upToDate.sort { $0.title < $1.title }
        
        return buckets
    }
}

