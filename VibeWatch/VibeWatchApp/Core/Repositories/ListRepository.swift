import Foundation

struct ListItemMutation {
    let userId: String
    let listId: String
    let item: MediaListItem
}

@MainActor
protocol ListRepository: AnyObject {
    func lists(for userId: String) -> AsyncStream<[MediaList]>
    func list(id: String, userId: String) -> AsyncStream<MediaList?>
    func contains(_ identifier: MediaIdentifier, in listType: ListType, userId: String) -> AsyncStream<Bool>

    func createList(_ list: MediaList, userId: String) async throws
    func updateList(_ list: MediaList, userId: String) async throws
    func deleteList(id: String, userId: String) async throws
    func addItem(_ mutation: ListItemMutation) async throws
    func removeItem(_ identifier: MediaIdentifier, from listId: String, userId: String) async throws
    func markAsSeen(_ identifier: MediaIdentifier, userId: String) async throws
}
