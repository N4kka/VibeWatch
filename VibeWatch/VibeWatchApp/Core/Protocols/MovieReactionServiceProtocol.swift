import Foundation

/// Protocol defining the movie reaction service interface.
/// Enables testability through dependency injection and mocking.
@MainActor
protocol MovieReactionServiceProtocol: AnyObject, ObservableObject {
    // MARK: - Reaction Queries

    func getReactionCounts(mediaId: Int, mediaType: MediaType) async throws -> MovieReactionCounts
    func getUserReaction(mediaId: Int, mediaType: MediaType, userId: String) async throws -> ReactionType?

    // MARK: - Reaction Management

    func toggleReaction(
        mediaId: Int,
        mediaType: MediaType,
        reaction: ReactionType,
        userId: String,
        userDisplayName: String?
    ) async throws

    func updateReactionCounts(
        mediaId: Int,
        mediaType: MediaType,
        oldReaction: ReactionType?,
        newReaction: ReactionType?
    ) async throws

    // MARK: - Cache Management

    func clearCache()
    func clearCache(for mediaId: Int, mediaType: MediaType)
}
