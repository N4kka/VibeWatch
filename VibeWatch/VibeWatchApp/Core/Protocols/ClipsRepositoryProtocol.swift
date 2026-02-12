import Foundation

/// Protocol defining the clips repository interface.
/// Enables testability through dependency injection and mocking.
@MainActor
protocol ClipsRepositoryProtocol: AnyObject {
    // MARK: - Clip Fetching

    func fetchClips(count: Int) async throws -> [Clip]
}
