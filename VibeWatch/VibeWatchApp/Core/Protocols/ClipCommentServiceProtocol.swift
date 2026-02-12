import Foundation

/// Protocol defining the clip comment service interface.
/// Enables testability through dependency injection and mocking.
@MainActor
protocol ClipCommentServiceProtocol: AnyObject, ObservableObject {
    // MARK: - Clip Likes

    func getClipLikeCount(clipId: String) async throws -> Int
    func hasUserLikedClip(clipId: String, userId: String) async throws -> Bool
    func toggleClipLike(
        clipId: String,
        userId: String,
        userDisplayName: String?
    ) async throws

    // MARK: - Comments

    func getComments(clipId: String, userId: String?, limit: Int) async throws -> [ClipComment]
    func getReplies(parentId: String, userId: String?, limit: Int) async throws -> [ClipComment]
    func postComment(
        clipId: String,
        userId: String,
        userDisplayName: String,
        content: String,
        parentId: String?
    ) async throws -> ClipComment
    func deleteComment(
        commentId: String,
        userId: String
    ) async throws

    // MARK: - Comment Likes

    func toggleCommentLike(
        commentId: String,
        userId: String,
        userDisplayName: String?
    ) async throws
    func hasUserLikedComment(commentId: String, userId: String) async throws -> Bool

    // MARK: - Cache Management

    func clearCache()
}
