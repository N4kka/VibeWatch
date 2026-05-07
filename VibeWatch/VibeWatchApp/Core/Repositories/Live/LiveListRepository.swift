import Foundation

/// Cache-first list loader. Emits ListManager.lists (already SQLite-backed) immediately,
/// then Supabase-refreshed after sync completes. Thin wrapper — mutation/sync stays in ListManager.
@MainActor
final class LiveListRepository: ListRepositoryProtocol {
    static let shared = LiveListRepository()
    private let listManager = ListManager.shared
    private init() {}

    nonisolated func observeLists(userId: String?) -> AsyncStream<[MediaList]> {
        AsyncStream { continuation in
            Task { @MainActor in
                // ListManager.lists is already loaded from SQLite at boot — instant
                continuation.yield(self.listManager.lists)

                // Supabase sync if authenticated
                if let userId, !userId.isEmpty {
                    await self.listManager.syncListsForAuthenticatedUser()
                    continuation.yield(self.listManager.lists)
                }
                continuation.finish()
            }
        }
    }
}
