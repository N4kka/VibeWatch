import Foundation

@MainActor
final class MockListRepository: ListRepository {
    var listsByUser: [String: [MediaList]] = [:]

    func lists(for userId: String) -> AsyncStream<[MediaList]> {
        AsyncStream { continuation in
            continuation.yield(listsByUser[userId] ?? [])
            continuation.finish()
        }
    }

    func list(id: String, userId: String) -> AsyncStream<MediaList?> {
        AsyncStream { continuation in
            continuation.yield(listsByUser[userId]?.first { $0.id == id })
            continuation.finish()
        }
    }

    func contains(_ identifier: MediaIdentifier, in listType: ListType, userId: String) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let contains = listsByUser[userId]?
                .first(where: { $0.type == listType })?
                .items
                .contains(where: { $0.mediaId == identifier.id && $0.mediaType == identifier.mediaType }) ?? false
            continuation.yield(contains)
            continuation.finish()
        }
    }

    func createList(_ list: MediaList, userId: String) async throws {
        listsByUser[userId, default: []].append(list)
    }

    func updateList(_ list: MediaList, userId: String) async throws {
        guard let index = listsByUser[userId]?.firstIndex(where: { $0.id == list.id }) else {
            listsByUser[userId, default: []].append(list)
            return
        }
        listsByUser[userId]?[index] = list
    }

    func deleteList(id: String, userId: String) async throws {
        listsByUser[userId]?.removeAll { $0.id == id }
    }

    func addItem(_ mutation: ListItemMutation) async throws {
        guard let index = listsByUser[mutation.userId]?.firstIndex(where: { $0.id == mutation.listId }),
              let existing = listsByUser[mutation.userId]?[index] else { return }
        var items = existing.items
        items.append(mutation.item)
        listsByUser[mutation.userId]?[index] = MediaList(
            id: existing.id,
            name: existing.name,
            description: existing.description,
            type: existing.type,
            createdAt: existing.createdAt,
            items: items
        )
    }

    func removeItem(_ identifier: MediaIdentifier, from listId: String, userId: String) async throws {
        guard let index = listsByUser[userId]?.firstIndex(where: { $0.id == listId }),
              let existing = listsByUser[userId]?[index] else { return }
        let items = existing.items.filter { $0.mediaId != identifier.id || $0.mediaType != identifier.mediaType }
        listsByUser[userId]?[index] = MediaList(
            id: existing.id,
            name: existing.name,
            description: existing.description,
            type: existing.type,
            createdAt: existing.createdAt,
            items: items
        )
    }

    func markAsSeen(_ identifier: MediaIdentifier, userId: String) async throws {
        let seenList = listsByUser[userId]?.first(where: { $0.type == .seen }) ?? MediaList(name: ListType.seen.displayName, type: .seen)
        if listsByUser[userId]?.contains(where: { $0.id == seenList.id }) != true {
            listsByUser[userId, default: []].append(seenList)
        }
        try await addItem(ListItemMutation(
            userId: userId,
            listId: seenList.id,
            item: MediaListItem(mediaId: identifier.id, mediaType: identifier.mediaType, title: "Seen #\(identifier.id)", posterPath: nil)
        ))
    }

    func addToDefaultList(type: ListType, item: MediaListItem, userId: String) async throws {
        let list = listsByUser[userId]?.first(where: { $0.type == type }) ?? MediaList(name: type.displayName, type: type)
        if listsByUser[userId]?.contains(where: { $0.id == list.id }) != true {
            listsByUser[userId, default: []].append(list)
        }
        try await addItem(ListItemMutation(userId: userId, listId: list.id, item: item))
    }

    func removeFromDefaultList(type: ListType, identifier: MediaIdentifier, userId: String) async throws {
        guard let list = listsByUser[userId]?.first(where: { $0.type == type }) else { return }
        try await removeItem(identifier, from: list.id, userId: userId)
    }

    func defaultListItems(type: ListType, userId: String) async throws -> [MediaListItem] {
        listsByUser[userId]?.first(where: { $0.type == type })?.items ?? []
    }
}
