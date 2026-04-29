import Foundation

@MainActor
final class LiveListRepository: ListRepository {
    typealias SyncQueue = @MainActor (String, String, String, [String: Any]) async throws -> Void
    typealias RemoteListsLoader = @MainActor (String) async throws -> [MediaList]

    private let db: SQLiteService
    private let syncQueue: SyncQueue
    private let remoteListsLoader: RemoteListsLoader

    init(
        db: SQLiteService = .shared,
        remoteListsLoader: @escaping RemoteListsLoader = { userId in
            guard SupabaseService.shared.currentUser?.id == userId else {
                return []
            }
            return try await SupabaseService.shared.fetchLists()
        },
        syncQueue: @escaping SyncQueue = { table, operationType, recordId, payload in
            try await SyncEngine.shared.queueOperation(
                table: table,
                operationType: operationType,
                recordId: recordId,
                payload: payload,
                dependsOn: nil
            )
        }
    ) {
        self.db = db
        self.remoteListsLoader = remoteListsLoader
        self.syncQueue = syncQueue
    }

    func lists(for userId: String) -> AsyncStream<[MediaList]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let localLists = (try? await loadLists(for: userId)) ?? []
                continuation.yield(localLists)

                do {
                    let remoteLists = try await remoteListsLoader(userId)
                    let normalizedRemoteLists = normalizeDefaultListDuplicates(remoteLists)
                    if !normalizedRemoteLists.isEmpty {
                        try await persistRemoteLists(normalizedRemoteLists, userId: userId)
                        continuation.yield((try? await loadLists(for: userId)) ?? normalizedRemoteLists)
                    }
                } catch {
                    Logger.warning("[LiveListRepository] Failed to hydrate remote lists: \(error.localizedDescription)")
                }

                continuation.finish()
            }
        }
    }

    func list(id: String, userId: String) -> AsyncStream<MediaList?> {
        AsyncStream { continuation in
            Task { @MainActor in
                continuation.yield(try? await loadList(id: id, userId: userId))
                continuation.finish()
            }
        }
    }

    func contains(_ identifier: MediaIdentifier, in listType: ListType, userId: String) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            Task { @MainActor in
                let rows = try? await db.queryRaw("""
                    SELECT li.id
                    FROM list_items li
                    JOIN lists l ON l.id = li.list_id
                    WHERE l.user_id = ? AND l.type = ? AND li.media_id = ? AND li.media_type = ?
                      AND l.deleted_at IS NULL AND li.deleted_at IS NULL
                    LIMIT 1
                """, parameters: [userId, listType.rawValue, identifier.id, identifier.mediaType.rawValue])
                continuation.yield(rows?.isEmpty == false)
                continuation.finish()
            }
        }
    }

    func createList(_ list: MediaList, userId: String) async throws {
        try await ensureProfile(userId: userId)
        let row = listRow(list, userId: userId)
        try await db.upsert(table: "lists", rows: [row])
        try await syncQueue("lists", "UPSERT", list.id, row)
    }

    func updateList(_ list: MediaList, userId: String) async throws {
        let row = listRow(list, userId: userId)
        try await db.upsert(table: "lists", rows: [row])
        try await syncQueue("lists", "UPDATE", list.id, row)
    }

    func deleteList(id: String, userId: String) async throws {
        try await db.update(
            "lists",
            values: ["deleted_at": RepositoryCoding.string(from: Date())],
            where: "id = ? AND user_id = ?",
            parameters: [id, userId]
        )
        try await syncQueue("lists", "DELETE", id, ["id": id, "user_id": userId])
    }

    func addItem(_ mutation: ListItemMutation) async throws {
        let row = itemRow(mutation.item, listId: mutation.listId, userId: mutation.userId)
        try await db.upsert(table: "list_items", rows: [row])
        try await syncQueue("list_items", "UPSERT", mutation.item.id, row)
    }

    func removeItem(_ identifier: MediaIdentifier, from listId: String, userId: String) async throws {
        try await db.update(
            "list_items",
            values: ["deleted_at": RepositoryCoding.string(from: Date())],
            where: "list_id = ? AND user_id = ? AND media_id = ? AND media_type = ?",
            parameters: [listId, userId, identifier.id, identifier.mediaType.rawValue]
        )
        try await syncQueue("list_items", "DELETE", "\(listId)-\(identifier.id)-\(identifier.mediaType.rawValue)", [
            "list_id": listId,
            "user_id": userId,
            "media_id": identifier.id,
            "media_type": identifier.mediaType.rawValue
        ])
    }

    func markAsSeen(_ identifier: MediaIdentifier, userId: String) async throws {
        let seenList = try await ensureDefaultList(type: .seen, userId: userId)
        let item = MediaListItem(
            mediaId: identifier.id,
            mediaType: identifier.mediaType,
            title: "Seen #\(identifier.id)",
            posterPath: nil
        )
        try await addItem(ListItemMutation(userId: userId, listId: seenList.id, item: item))
    }

    func addToDefaultList(type: ListType, item: MediaListItem, userId: String) async throws {
        let list = try await ensureDefaultList(type: type, userId: userId)
        try await addItem(ListItemMutation(userId: userId, listId: list.id, item: item))
    }

    func removeFromDefaultList(type: ListType, identifier: MediaIdentifier, userId: String) async throws {
        guard let list = try await loadLists(for: userId).first(where: { $0.type == type }) else { return }
        try await removeItem(identifier, from: list.id, userId: userId)
    }

    func defaultListItems(type: ListType, userId: String) async throws -> [MediaListItem] {
        let lists = try await loadLists(for: userId)
        return lists.first(where: { $0.type == type })?.items ?? []
    }

    private func loadLists(for userId: String) async throws -> [MediaList] {
        let listRows = try await db.queryRaw("""
            SELECT * FROM lists
            WHERE user_id = ? AND deleted_at IS NULL
            ORDER BY created_at DESC
        """, parameters: [userId])
        guard !listRows.isEmpty else { return [] }

        let listIds = listRows.compactMap { $0["id"] as? String }
        let placeholders = listIds.map { _ in "?" }.joined(separator: ",")
        let itemRows = try await db.queryRaw("""
            SELECT * FROM list_items
            WHERE list_id IN (\(placeholders)) AND deleted_at IS NULL
            ORDER BY added_at DESC
        """, parameters: listIds)

        var itemsByList: [String: [MediaListItem]] = [:]
        for row in itemRows {
            guard let listId = row["list_id"] as? String,
                  let item = MediaListItem.from(dictionary: row) else { continue }
            itemsByList[listId, default: []].append(item)
        }

        let lists: [MediaList] = listRows.compactMap { row in
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String,
                  let typeRaw = row["type"] as? String,
                  let type = ListType(rawValue: typeRaw) else {
                return nil
            }
            return MediaList(
                id: id,
                name: name,
                description: row["description"] as? String,
                type: type,
                createdAt: RepositoryCoding.date(from: row["created_at"]) ?? Date(),
                items: itemsByList[id] ?? []
            )
        }

        return normalizeDefaultListDuplicates(lists)
    }

    private func loadList(id: String, userId: String) async throws -> MediaList? {
        try await loadLists(for: userId).first { $0.id == id }
    }

    private func normalizeDefaultListDuplicates(_ lists: [MediaList]) -> [MediaList] {
        let defaultTypes: Set<ListType> = [.watchlist, .seen, .liked, .disliked]
        let groupedDefaults = Dictionary(grouping: lists.filter { defaultTypes.contains($0.type) }, by: \.type)
        let mergedDefaults = groupedDefaults.mapValues(mergeDefaultLists)
        var emittedTypes = Set<ListType>()

        return lists.compactMap { list in
            guard defaultTypes.contains(list.type) else { return list }
            guard !emittedTypes.contains(list.type) else { return nil }
            emittedTypes.insert(list.type)
            return mergedDefaults[list.type] ?? list
        }
    }

    private func mergeDefaultLists(_ lists: [MediaList]) -> MediaList {
        guard let canonical = lists.max(by: { lhs, rhs in
            if lhs.items.count != rhs.items.count {
                return lhs.items.count < rhs.items.count
            }
            return lhs.createdAt < rhs.createdAt
        }) else {
            return MediaList(name: ListType.watchlist.displayName, type: .watchlist)
        }

        var itemsByIdentity: [String: MediaListItem] = [:]
        for item in lists.flatMap(\.items) {
            let key = "\(item.mediaType.rawValue):\(item.mediaId)"
            if let existing = itemsByIdentity[key], existing.addedAt >= item.addedAt {
                continue
            }
            itemsByIdentity[key] = item
        }

        let items = itemsByIdentity.values.sorted { $0.addedAt > $1.addedAt }
        return MediaList(
            id: canonical.id,
            name: canonical.name,
            description: canonical.description,
            type: canonical.type,
            createdAt: canonical.createdAt,
            items: items
        )
    }

    private func persistRemoteLists(_ lists: [MediaList], userId: String) async throws {
        try await ensureProfile(userId: userId)
        try await db.upsert(table: "lists", rows: lists.map { listRow($0, userId: userId) })

        let itemRows = lists.flatMap { list in
            list.items.map { itemRow($0, listId: list.id, userId: userId) }
        }
        try await db.upsert(table: "list_items", rows: itemRows)
    }

    private func ensureDefaultList(type: ListType, userId: String) async throws -> MediaList {
        if let existingList = try await loadLists(for: userId).first(where: { $0.type == type }) {
            return existingList
        }

        let list = MediaList(name: type.displayName, type: type)
        try await createList(list, userId: userId)
        return list
    }

    private func ensureProfile(userId: String) async throws {
        try await db.upsert(table: "profiles", rows: [[
            "id": userId,
            "email": "local@vibewatch",
            "display_name": "Local User",
            "created_at": RepositoryCoding.string(from: Date()),
            "updated_at": RepositoryCoding.string(from: Date())
        ]])
    }

    private func listRow(_ list: MediaList, userId: String) -> [String: Any] {
        [
            "id": list.id,
            "user_id": userId,
            "name": list.name,
            "description": list.description ?? NSNull(),
            "type": list.type.rawValue,
            "created_at": RepositoryCoding.string(from: list.createdAt),
            "updated_at": RepositoryCoding.string(from: Date())
        ]
    }

    private func itemRow(_ item: MediaListItem, listId: String, userId: String) -> [String: Any] {
        [
            "id": item.id,
            "list_id": listId,
            "user_id": userId,
            "media_id": item.mediaId,
            "media_type": item.mediaType.rawValue,
            "title": item.title,
            "poster_path": item.posterPath ?? NSNull(),
            "runtime": item.runtime ?? NSNull(),
            "vote_average": item.voteAverage ?? NSNull(),
            "vote_count": item.voteCount ?? NSNull(),
            "origin_country": (try? RepositoryCoding.jsonString(item.originCountry ?? [])) ?? "[]",
            "release_date": item.releaseDate ?? NSNull(),
            "genres": (try? RepositoryCoding.jsonString(item.genres ?? [])) ?? "[]",
            "overview": item.overview ?? NSNull(),
            "added_at": RepositoryCoding.string(from: item.addedAt),
            "updated_at": RepositoryCoding.string(from: Date())
        ]
    }
}
