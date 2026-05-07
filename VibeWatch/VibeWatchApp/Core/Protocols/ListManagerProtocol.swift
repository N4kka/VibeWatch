import Foundation
import Combine

/// Protocol defining the list management service interface.
/// Enables testability through dependency injection and mocking.
@MainActor
protocol ListManagerProtocol: AnyObject, ObservableObject {
    // MARK: - Published Properties

    var lists: [MediaList] { get }
    var watchlist: MediaList { get }
    var seenList: MediaList { get }
    var likedList: MediaList { get }
    var dislikedList: MediaList { get }
    var softLimitWarningMessage: String? { get set }

    // MARK: - Computed Properties

    var currentCustomListLimit: Int { get }

    // MARK: - Lifecycle Methods

    func syncListsForAuthenticatedUser() async
    func resetListsForLoggedOutUser()
    func loadLists()

    // MARK: - List CRUD Operations

    func fetchLists() async throws -> [MediaList]
    func createList(name: String, description: String?) async throws -> MediaList
    func updateList(id: String, name: String, description: String?) async throws
    func deleteList(id: String) async throws

    // MARK: - List Item Operations

    func addToList(
        listId: String,
        mediaId: Int,
        mediaType: MediaType,
        posterPath: String?,
        title: String
    ) async throws
    func removeFromList(listId: String, itemId: String) async throws
    func getItems(listId: String) async throws -> [MediaListItem]
    func isInList(listId: String, mediaId: Int, mediaType: MediaType) -> Bool

    // MARK: - Validation

    func canCreateList() -> Bool
    func canAddToList(listId: String) -> Bool
    func customListsCount() -> Int
}
