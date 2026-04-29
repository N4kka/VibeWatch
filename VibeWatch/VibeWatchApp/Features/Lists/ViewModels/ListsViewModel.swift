import Foundation
import Observation

@MainActor
@Observable
final class ListsViewModel {
    var lists: [MediaList] = []
    var isLoading = false
    var error: AppError?

    private let repository: any ListRepository
    private let userId: String

    init(repository: any ListRepository, userId: String) {
        self.repository = repository
        self.userId = userId
    }

    var watchlist: MediaList {
        defaultList(type: .watchlist)
    }

    var seenList: MediaList {
        defaultList(type: .seen)
    }

    var likedList: MediaList {
        defaultList(type: .liked)
    }

    var customLists: [MediaList] {
        lists.filter { $0.type == .custom }
    }

    func loadLists() async {
        isLoading = true
        error = nil

        for await snapshot in repository.lists(for: userId) {
            lists = snapshot
            break
        }

        isLoading = false
    }

    func createList(title: String, description: String?) async throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw ListError.invalidName }

        let list = MediaList(
            name: trimmedTitle,
            description: description,
            type: .custom
        )
        try await repository.createList(list, userId: userId)
        lists.append(list)
    }

    func deleteList(_ list: MediaList) async throws {
        try await repository.deleteList(id: list.id, userId: userId)
        lists.removeAll { $0.id == list.id }
    }

    func updateList(_ list: MediaList, name: String, description: String?) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ListError.invalidName }

        let updated = MediaList(
            id: list.id,
            name: trimmedName,
            description: description,
            type: list.type,
            createdAt: list.createdAt,
            items: list.items
        )
        try await repository.updateList(updated, userId: userId)
        replaceList(updated)
    }

    func removeItem(_ item: MediaListItem, from list: MediaList) async throws {
        let identifier = MediaIdentifier(id: item.mediaId, mediaType: item.mediaType)
        try await repository.removeItem(identifier, from: list.id, userId: userId)
        removeLocalItem(identifier, from: list.id)
    }

    func markAsSeen(_ item: MediaListItem) async throws {
        let identifier = MediaIdentifier(id: item.mediaId, mediaType: item.mediaType)
        try await repository.markAsSeen(identifier, userId: userId)
        appendLocalItem(item, to: .seen)
    }

    func addToWatchlist(_ item: MediaListItem) async throws {
        let watchlist = try await ensureLocalDefaultList(type: .watchlist)
        try await repository.addItem(ListItemMutation(userId: userId, listId: watchlist.id, item: item))
        appendLocalItem(item, to: .watchlist)
    }

    func containsSeen(_ item: MediaListItem) -> Bool {
        seenList.items.contains { $0.mediaId == item.mediaId && $0.mediaType == item.mediaType }
    }

    func customListsCount() -> Int {
        customLists.count
    }

    func currentCustomListLimit(isProUser: Bool) -> Int {
        isProUser ? ListManager.proMaxCustomLists : ListManager.freeMaxCustomLists
    }

    func canCreateList(isProUser: Bool) -> Bool {
        customListsCount() < currentCustomListLimit(isProUser: isProUser)
    }

    private func defaultList(type: ListType) -> MediaList {
        lists.first { $0.type == type } ?? MediaList(name: type.displayName, type: type)
    }

    private func ensureLocalDefaultList(type: ListType) async throws -> MediaList {
        if let list = lists.first(where: { $0.type == type }) {
            return list
        }

        let list = MediaList(name: type.displayName, type: type)
        try await repository.createList(list, userId: userId)
        lists.append(list)
        return list
    }

    private func replaceList(_ list: MediaList) {
        if let index = lists.firstIndex(where: { $0.id == list.id }) {
            lists[index] = list
        } else {
            lists.append(list)
        }
    }

    private func appendLocalItem(_ item: MediaListItem, to type: ListType) {
        let list = defaultList(type: type)
        var items = list.items
        guard !items.contains(where: { $0.mediaId == item.mediaId && $0.mediaType == item.mediaType }) else {
            return
        }
        items.append(item)
        replaceList(MediaList(
            id: list.id,
            name: list.name,
            description: list.description,
            type: list.type,
            createdAt: list.createdAt,
            items: items
        ))
    }

    private func removeLocalItem(_ identifier: MediaIdentifier, from listId: String) {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }
        var list = lists[index]
        list.items.removeAll { $0.mediaId == identifier.id && $0.mediaType == identifier.mediaType }
        lists[index] = list
    }
}
