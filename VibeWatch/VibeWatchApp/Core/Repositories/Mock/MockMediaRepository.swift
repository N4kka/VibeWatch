import Foundation

@MainActor
final class MockMediaRepository: MediaRepository {
    var detailsByIdentifier: [MediaIdentifier: MediaDetailsSnapshot] = [:]
    var availabilityByKey: [String: MediaAvailabilitySnapshot] = [:]

    func details(for identifier: MediaIdentifier) -> AsyncStream<MediaDetailsSnapshot?> {
        AsyncStream { continuation in
            continuation.yield(detailsByIdentifier[identifier])
            continuation.finish()
        }
    }

    func availability(for identifier: MediaIdentifier, region: String) -> AsyncStream<MediaAvailabilitySnapshot?> {
        AsyncStream { continuation in
            continuation.yield(availabilityByKey[key(identifier, region)])
            continuation.finish()
        }
    }

    func refreshDetails(for identifier: MediaIdentifier) async throws {}
    func refreshAvailability(for identifier: MediaIdentifier, region: String) async throws {}
    func invalidateDetails(for identifier: MediaIdentifier) async throws {
        detailsByIdentifier.removeValue(forKey: identifier)
    }
    func invalidateAvailability(for identifier: MediaIdentifier, region: String) async throws {
        availabilityByKey.removeValue(forKey: key(identifier, region))
    }

    private func key(_ identifier: MediaIdentifier, _ region: String) -> String {
        "\(identifier.mediaType.rawValue)-\(identifier.id)-\(region)"
    }
}
