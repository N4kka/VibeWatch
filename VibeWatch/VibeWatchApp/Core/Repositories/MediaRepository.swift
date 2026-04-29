import Foundation

struct MediaIdentifier: Hashable, Codable {
    let id: Int
    let mediaType: MediaType
}

enum MediaDetailsSnapshot {
    case movie(Movie)
    case tvShow(TVShow)
}

struct MediaAvailabilitySnapshot {
    let identifier: MediaIdentifier
    let region: String
    let providers: WatchProvider
    let cachedAt: Date
    let expiresAt: Date
}

@MainActor
protocol MediaRepository: AnyObject, Sendable {
    func details(for identifier: MediaIdentifier) -> AsyncStream<MediaDetailsSnapshot?>
    func availability(for identifier: MediaIdentifier, region: String) -> AsyncStream<MediaAvailabilitySnapshot?>

    func refreshDetails(for identifier: MediaIdentifier) async throws
    func refreshAvailability(for identifier: MediaIdentifier, region: String) async throws
    func invalidateDetails(for identifier: MediaIdentifier) async throws
    func invalidateAvailability(for identifier: MediaIdentifier, region: String) async throws
}
