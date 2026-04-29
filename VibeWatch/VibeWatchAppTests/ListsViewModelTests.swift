import XCTest
@testable import VibeWatchApp

@MainActor
final class ListsViewModelTests: XCTestCase {
    func testLoadListsUsesInjectedRepositorySnapshot() async {
        let userId = "lists-view-model-user"
        let repository = MockListRepository()
        repository.listsByUser[userId] = [
            MediaList(id: "watchlist", name: "Watchlist", type: .watchlist),
            MediaList(id: "custom", name: "Weekend", type: .custom)
        ]
        let viewModel = ListsViewModel(repository: repository, userId: userId)

        await viewModel.loadLists()

        XCTAssertEqual(viewModel.lists.map(\.id), ["watchlist", "custom"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
    }

    func testCreateListPersistsThroughInjectedRepository() async throws {
        let userId = "lists-view-model-create-user"
        let repository = MockListRepository()
        let viewModel = ListsViewModel(repository: repository, userId: userId)

        try await viewModel.createList(title: "Weekend", description: "Short queue")

        let created = try XCTUnwrap(repository.listsByUser[userId]?.first)
        XCTAssertEqual(created.name, "Weekend")
        XCTAssertEqual(created.description, "Short queue")
        XCTAssertEqual(created.type, .custom)
    }

    func testLoadListsKeepsLatestRepositorySnapshot() async {
        let userId = "lists-view-model-stream-user"
        let repository = SnapshotListRepository(snapshots: [
            [],
            [MediaList(id: "remote-watchlist", name: "Da Vedere", type: .watchlist)]
        ])
        let viewModel = ListsViewModel(repository: repository, userId: userId)

        await viewModel.loadLists()

        XCTAssertEqual(viewModel.lists.map(\.id), ["remote-watchlist"])
        XCTAssertFalse(viewModel.isLoading)
    }
}

@MainActor
final class LiveListRepositoryTests: XCTestCase {
    private let db = SQLiteService.shared

    override func tearDown() async throws {
        try await db.delete(
            "list_items",
            where: "user_id LIKE ?",
            parameters: ["live-list-repo-test-%"],
            hard: true
        )
        try await db.delete(
            "lists",
            where: "user_id LIKE ?",
            parameters: ["live-list-repo-test-%"],
            hard: true
        )
        try await db.delete(
            "profiles",
            where: "id LIKE ?",
            parameters: ["live-list-repo-test-%"],
            hard: true
        )
        try await super.tearDown()
    }

    func testListsHydratesRemoteListsIntoLocalStore() async throws {
        let userId = "live-list-repo-test-\(UUID().uuidString)"
        let listId = "remote-watchlist-\(UUID().uuidString)"
        let remoteItem = MediaListItem(
            id: "remote-item-\(UUID().uuidString)",
            mediaId: 27205,
            mediaType: .movie,
            title: "Inception",
            posterPath: "/inception.jpg",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            runtime: 148,
            voteAverage: 8.4,
            voteCount: 36_000,
            originCountry: ["US"],
            releaseDate: "2010-07-16",
            genres: [28, 878],
            overview: "A thief who steals corporate secrets through dream-sharing technology."
        )
        let remoteList = MediaList(
            id: listId,
            name: "Da Vedere",
            type: .watchlist,
            createdAt: Date(timeIntervalSince1970: 1_690_000_000),
            items: [remoteItem]
        )
        let repository = LiveListRepository(
            db: db,
            remoteListsLoader: { requestedUserId in
                XCTAssertEqual(requestedUserId, userId)
                return [remoteList]
            },
            syncQueue: { _, _, _, _ in
                XCTFail("Hydrating remote lists should not enqueue outbound sync")
            }
        )

        var snapshots: [[MediaList]] = []
        for await lists in repository.lists(for: userId) {
            snapshots.append(lists)
        }

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots[0].isEmpty)
        XCTAssertEqual(snapshots[1].first?.id, listId)
        XCTAssertEqual(snapshots[1].first?.items.first?.mediaId, 27205)

        let persistedItems = try await db.queryRaw(
            "SELECT media_id, title FROM list_items WHERE user_id = ? AND list_id = ?",
            parameters: [userId, listId]
        )
        XCTAssertEqual(persistedItems.count, 1)
        XCTAssertEqual(persistedItems.first?["media_id"] as? Int, 27205)
        XCTAssertEqual(persistedItems.first?["title"] as? String, "Inception")
    }

    func testListsMergesDuplicateRemoteDefaultListsUsingLargestList() async throws {
        let userId = "live-list-repo-test-\(UUID().uuidString)"
        let fullListId = "remote-full-watchlist-\(UUID().uuidString)"
        let emptyListId = "remote-empty-watchlist-\(UUID().uuidString)"
        let remoteItem = MediaListItem(
            id: "remote-item-\(UUID().uuidString)",
            mediaId: 550,
            mediaType: .movie,
            title: "Fight Club",
            posterPath: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let fullWatchlist = MediaList(
            id: fullListId,
            name: "Watchlist",
            type: .watchlist,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            items: [remoteItem]
        )
        let newerEmptyWatchlist = MediaList(
            id: emptyListId,
            name: "Watchlist",
            type: .watchlist,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            items: []
        )
        let repository = LiveListRepository(
            db: db,
            remoteListsLoader: { _ in [newerEmptyWatchlist, fullWatchlist] },
            syncQueue: { _, _, _, _ in
                XCTFail("Hydrating remote lists should not enqueue outbound sync")
            }
        )

        var snapshots: [[MediaList]] = []
        for await lists in repository.lists(for: userId) {
            snapshots.append(lists)
        }

        let watchlists = snapshots.last?.filter { $0.type == .watchlist } ?? []
        XCTAssertEqual(watchlists.count, 1)
        XCTAssertEqual(watchlists.first?.id, fullListId)
        XCTAssertEqual(watchlists.first?.items.map(\.mediaId), [550])
    }

    func testMarkAsSeenUsesMergedDefaultSeenList() async throws {
        let userId = "live-list-repo-test-\(UUID().uuidString)"
        let fullSeenListId = "local-full-seen-\(UUID().uuidString)"
        let emptySeenListId = "local-empty-seen-\(UUID().uuidString)"
        let olderDate = RepositoryCoding.string(from: Date(timeIntervalSince1970: 1_600_000_000))
        let newerDate = RepositoryCoding.string(from: Date(timeIntervalSince1970: 1_800_000_000))

        try await db.upsert(table: "profiles", rows: [[
            "id": userId,
            "email": "test@example.com",
            "display_name": "Test User",
            "created_at": olderDate,
            "updated_at": olderDate
        ]])
        try await db.upsert(table: "lists", rows: [
            [
                "id": emptySeenListId,
                "user_id": userId,
                "name": "Seen",
                "type": "seen",
                "created_at": newerDate,
                "updated_at": newerDate
            ],
            [
                "id": fullSeenListId,
                "user_id": userId,
                "name": "Seen",
                "type": "seen",
                "created_at": olderDate,
                "updated_at": olderDate
            ]
        ])
        try await db.upsert(table: "list_items", rows: [[
            "id": "existing-seen-item-\(UUID().uuidString)",
            "list_id": fullSeenListId,
            "user_id": userId,
            "media_id": 550,
            "media_type": "movie",
            "title": "Fight Club",
            "added_at": olderDate,
            "updated_at": olderDate
        ]])

        let repository = LiveListRepository(
            db: db,
            remoteListsLoader: { _ in [] },
            syncQueue: { table, operationType, _, payload in
                XCTAssertEqual(table, "list_items")
                XCTAssertEqual(operationType, "UPSERT")
                XCTAssertEqual(payload["list_id"] as? String, fullSeenListId)
            }
        )

        try await repository.markAsSeen(MediaIdentifier(id: 551, mediaType: .movie), userId: userId)

        let fullListRows = try await db.queryRaw(
            "SELECT id FROM list_items WHERE user_id = ? AND list_id = ? AND media_id = ? AND deleted_at IS NULL",
            parameters: [userId, fullSeenListId, 551]
        )
        let emptyListRows = try await db.queryRaw(
            "SELECT id FROM list_items WHERE user_id = ? AND list_id = ? AND media_id = ? AND deleted_at IS NULL",
            parameters: [userId, emptySeenListId, 551]
        )
        XCTAssertEqual(fullListRows.count, 1)
        XCTAssertTrue(emptyListRows.isEmpty)
    }
}

@MainActor
private final class SnapshotListRepository: ListRepository {
    let snapshots: [[MediaList]]

    init(snapshots: [[MediaList]]) {
        self.snapshots = snapshots
    }

    func lists(for userId: String) -> AsyncStream<[MediaList]> {
        AsyncStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }

    func list(id: String, userId: String) -> AsyncStream<MediaList?> {
        AsyncStream { continuation in
            continuation.yield(snapshots.last?.first { $0.id == id })
            continuation.finish()
        }
    }

    func contains(_ identifier: MediaIdentifier, in listType: ListType, userId: String) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(false)
            continuation.finish()
        }
    }

    func createList(_ list: MediaList, userId: String) async throws {}
    func updateList(_ list: MediaList, userId: String) async throws {}
    func deleteList(id: String, userId: String) async throws {}
    func addItem(_ mutation: ListItemMutation) async throws {}
    func removeItem(_ identifier: MediaIdentifier, from listId: String, userId: String) async throws {}
    func markAsSeen(_ identifier: MediaIdentifier, userId: String) async throws {}
}
