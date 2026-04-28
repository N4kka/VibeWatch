import XCTest
@testable import VibeWatchApp

@MainActor
final class LiveMediaRepositoryTests: XCTestCase {
    private let db = SQLiteService.shared
    private let formatter = ISO8601DateFormatter()

    func testDetailsStreamYieldsCachedSnapshotThenFreshSnapshotWhenMetadataIsExpired() async throws {
        let mediaId = 8_900_001
        try await db.delete(
            "media_details_cache",
            where: "tmdb_id = ? AND media_type = ?",
            parameters: [mediaId, MediaType.movie.rawValue],
            hard: true
        )

        let now = Date()
        try await db.upsert(table: "media_details_cache", rows: [[
            "tmdb_id": mediaId,
            "media_type": MediaType.movie.rawValue,
            "title": "Cached title",
            "overview": "Cached overview",
            "poster_path": "/cached.jpg",
            "backdrop_path": "/cached-backdrop.jpg",
            "cached_at": formatter.string(from: now.addingTimeInterval(-7200)),
            "expires_at": formatter.string(from: now.addingTimeInterval(-60)),
            "metadata_expires_at": formatter.string(from: now.addingTimeInterval(-60)),
            "availability_expires_at": formatter.string(from: now.addingTimeInterval(43_200))
        ]])

        let repository = LiveMediaRepository(
            db: db,
            movieDetailsProvider: { id in
                Movie.repositoryTestFixture(id: id, title: "Fresh title")
            },
            tvShowDetailsProvider: { id in
                TVShow.repositoryTestFixture(id: id, name: "Fresh show")
            },
            movieWatchProvider: { _ in WatchProvider(results: [:]) },
            tvShowWatchProvider: { _ in WatchProvider(results: [:]) }
        )

        var snapshots: [MediaDetailsSnapshot?] = []
        for await snapshot in repository.details(for: MediaIdentifier(id: mediaId, mediaType: .movie)) {
            snapshots.append(snapshot)
            if snapshots.count == 2 { break }
        }

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0]?.movieTitle, "Cached title")
        XCTAssertEqual(snapshots[1]?.movieTitle, "Fresh title")
    }

    func testAvailabilityRefreshStoresTwelveHourTTL() async throws {
        let mediaId = 8_900_002
        let beforeRefresh = Date()
        try await db.delete(
            "media_availability",
            where: "tmdb_id = ? AND media_type = ? AND region = ?",
            parameters: [mediaId, MediaType.movie.rawValue, "US"],
            hard: true
        )

        let repository = LiveMediaRepository(
            db: db,
            movieDetailsProvider: { id in Movie.repositoryTestFixture(id: id, title: "Movie") },
            tvShowDetailsProvider: { id in TVShow.repositoryTestFixture(id: id, name: "Show") },
            movieWatchProvider: { _ in
                WatchProvider(results: ["US": CountryProviders(flatrate: [], rent: nil, buy: nil, link: nil)])
            },
            tvShowWatchProvider: { _ in WatchProvider(results: [:]) }
        )

        try await repository.refreshAvailability(
            for: MediaIdentifier(id: mediaId, mediaType: .movie),
            region: "US"
        )

        let rows = try await db.queryRaw(
            "SELECT expires_at FROM media_availability WHERE tmdb_id = ? AND media_type = ? AND region = ?",
            parameters: [mediaId, MediaType.movie.rawValue, "US"]
        )
        let expiresAtString = try XCTUnwrap(rows.first?["expires_at"] as? String)
        let expiresAt = try XCTUnwrap(formatter.date(from: expiresAtString))

        XCTAssertGreaterThanOrEqual(expiresAt.timeIntervalSince(beforeRefresh), 11.5 * 60 * 60)
        XCTAssertLessThanOrEqual(expiresAt.timeIntervalSince(beforeRefresh), 12.5 * 60 * 60)
    }
}

private extension MediaDetailsSnapshot {
    var movieTitle: String? {
        if case let .movie(movie) = self {
            return movie.title
        }
        return nil
    }
}
