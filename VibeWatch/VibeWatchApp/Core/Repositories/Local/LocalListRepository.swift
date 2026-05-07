import Foundation

/// Reads cached lists from SQLite via ListManager. Never touches the network.
@MainActor
final class LocalListRepository: ListRepositoryProtocol {
    static let shared = LocalListRepository()
    private let listManager = ListManager.shared
    private init() {}

    nonisolated func observeLists(userId: String?) -> AsyncStream<[MediaList]> {
        AsyncStream { continuation in
            Task { @MainActor in
                continuation.yield(self.listManager.lists)
                continuation.finish()
            }
        }
    }
}
