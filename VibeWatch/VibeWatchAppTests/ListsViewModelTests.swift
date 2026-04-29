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
}
