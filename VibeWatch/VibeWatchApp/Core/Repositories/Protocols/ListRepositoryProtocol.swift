import Foundation

protocol ListRepositoryProtocol: Sendable {
    /// Cache-first: emits SQLite-cached lists immediately, then Supabase-refreshed on auth.
    func observeLists(userId: String?) -> AsyncStream<[MediaList]>
}
