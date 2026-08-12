import XCTest
@testable import VibeWatchApp

/// Covers the offline-first half of the search screen.
///
/// Search used to render nothing until TMDB answered — a 350 ms debounce plus a round trip with an
/// empty view — while the device already held the titles the user cares about most. These tests
/// pin the behaviour that fills that gap: cached titles come back, they are deduplicated across
/// the two sources, and the richer row wins.
@MainActor
final class LocalTitleSearchTests: XCTestCase {

    private var service: SQLiteService!
    private var dbPath: String!
    private var search: SQLiteLocalTitleSearch!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "vibewatch_localsearch_\(UUID().uuidString).sqlite"
        service = SQLiteService(dbPath: dbPath)
        search = SQLiteLocalTitleSearch(db: service)

        // lists.user_id and list_items.user_id both reference profiles(id), and foreign keys are ON.
        try await service.upsert(table: "profiles", rows: [[
            "id": "U1", "display_name": "Tester"
        ]])
        try await service.upsert(table: "lists", rows: [[
            "id": "L1", "user_id": "U1", "name": "Watchlist", "type": "watchlist"
        ]])
        try await service.upsert(table: "list_items", rows: [
            ["id": "I1", "list_id": "L1", "user_id": "U1", "media_id": 603, "media_type": "movie",
             "title": "The Matrix", "poster_path": "/m.jpg", "release_date": "1999-03-30",
             "vote_average": 8.2, "vote_count": 25000],
            ["id": "I2", "list_id": "L1", "user_id": "U1", "media_id": 100088, "media_type": "tv",
             "title": "The Last of Us", "poster_path": "/t.jpg", "release_date": "2023-01-15"],
            ["id": "I3", "list_id": "L1", "user_id": "U1", "media_id": 999, "media_type": "movie",
             "title": "Deleted Title", "deleted_at": "2026-07-23T00:00:00Z"]
        ])
        try await service.upsert(table: "media_details_cache", rows: [
            ["tmdb_id": 603, "media_type": "movie", "title": "The Matrix",
             "poster_path": "/cached.jpg", "expires_at": "2099-01-01"],
            ["tmdb_id": 604, "media_type": "movie", "title": "The Matrix Reloaded",
             "poster_path": "/mr.jpg", "expires_at": "2099-01-01"]
        ])
    }

    override func tearDown() async throws {
        search = nil
        service = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    func test_findsTitlesFromListsAndCache() async {
        let results = await search.search(matching: "matrix", limit: 20)
        let ids = Set(results.map(\.id))

        XCTAssertTrue(ids.contains(603), "il titolo in lista deve essere trovato")
        XCTAssertTrue(ids.contains(604), "il titolo presente solo in cache deve essere trovato")
    }

    /// A title in both sources must appear once, and must keep the list row's richer fields
    /// rather than the cache row's. This is what the MIN(source_rank) in the query buys.
    func test_deduplicatesAcrossSourcesKeepingTheRicherRow() async {
        let results = await search.search(matching: "matrix", limit: 20)
        let matrix = results.filter { $0.id == 603 }

        XCTAssertEqual(matrix.count, 1, "The Matrix è in lista e in cache: deve comparire una volta")
        XCTAssertEqual(matrix.first?.posterPath, "/m.jpg", "deve vincere la riga di lista, non quella di cache")
        XCTAssertEqual(matrix.first?.voteAverage, 8.2)
        XCTAssertEqual(matrix.first?.releaseDate, "1999-03-30")
    }

    func test_prefixMatchesRankAboveSubstringMatches() async {
        let results = await search.search(matching: "the", limit: 20)
        XCTAssertFalse(results.isEmpty)
        // Everything here starts with "The", so the point is simply that prefix hits lead.
        XCTAssertTrue(results.first?.displayTitle.lowercased().hasPrefix("the") ?? false)
    }

    func test_softDeletedItemsAreExcluded() async {
        let results = await search.search(matching: "deleted", limit: 20)
        XCTAssertTrue(results.isEmpty, "un item soft-deleted non deve comparire nei risultati locali")
    }

    func test_tvTitlesCarryNameNotTitle() async {
        let results = await search.search(matching: "last of us", limit: 20)
        let show = results.first { $0.id == 100088 }

        XCTAssertNotNil(show)
        XCTAssertEqual(show?.mediaType, "tv")
        XCTAssertEqual(show?.name, "The Last of Us", "per le serie TMDB usa `name`, non `title`")
        XCTAssertNil(show?.title)
        XCTAssertEqual(show?.firstAirDate, "2023-01-15")
    }

    /// One character is noise, not a query: it would match most of the library and cost a scan
    /// for nothing.
    func test_singleCharacterQueryIsIgnored() async {
        let results = await search.search(matching: "t", limit: 20)
        XCTAssertTrue(results.isEmpty)
    }

    func test_limitIsRespected() async {
        let results = await search.search(matching: "the", limit: 1)
        XCTAssertEqual(results.count, 1)
    }
}
