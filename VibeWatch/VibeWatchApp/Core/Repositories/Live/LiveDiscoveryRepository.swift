import Foundation

@MainActor
final class LiveDiscoveryRepository: DiscoveryRepository {
    typealias CarouselProvider = (String, GlobalDiscoveryFilters) async throws -> [DiscoveryCarouselSnapshot]

    private let db: SQLiteService
    private let carouselProvider: CarouselProvider
    private let cacheTTL: TimeInterval

    init(
        db: SQLiteService = .shared,
        carouselProvider: @escaping CarouselProvider = { userId, filters in
            let profile = await UserPreferenceManager.shared.aggregatePreferences()
            return try await DiscoveryPersonalizationService.shared.generatePersonalizedCarousels(
                userProfile: profile,
                filters: filters,
                forceRefresh: true
            )
            .enumerated()
            .map { index, carousel in
                DiscoveryCarouselSnapshot(
                    type: carousel.type.rawValue,
                    title: carousel.title,
                    mediaType: .movie,
                    position: index,
                    items: carousel.items,
                    cachedAt: Date(),
                    expiresAt: Date().addingTimeInterval(6 * 60 * 60)
                )
            }
        },
        cacheTTL: TimeInterval = 6 * 60 * 60
    ) {
        self.db = db
        self.carouselProvider = carouselProvider
        self.cacheTTL = cacheTTL
    }

    func carousels(for userId: String, filters: GlobalDiscoveryFilters) -> AsyncStream<[DiscoveryCarouselSnapshot]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let cached = (try? await cachedCarousels(for: userId)) ?? []
                if !cached.isEmpty {
                    continuation.yield(cached)
                }

                if cached.isEmpty || cached.contains(where: { $0.expiresAt <= Date() }) {
                    try? await refreshCarousels(for: userId, filters: filters)
                    continuation.yield((try? await cachedCarousels(for: userId)) ?? [])
                }

                continuation.finish()
            }
        }
    }

    func refreshCarousels(for userId: String, filters: GlobalDiscoveryFilters) async throws {
        let now = Date()
        let normalized = normalizePositions(try await carouselProvider(userId, filters), cachedAt: now)

        db.execute("DELETE FROM discovery_carousel_items WHERE carousel_id IN (SELECT id FROM discovery_carousels WHERE user_id = ?)", parameters: [userId])
        db.execute("DELETE FROM discovery_carousels WHERE user_id = ?", parameters: [userId])

        for carousel in normalized {
            let carouselId = self.carouselId(userId: userId, type: carousel.type, mediaType: carousel.mediaType)
            try await db.upsert(table: "discovery_carousels", rows: [[
                "id": carouselId,
                "user_id": userId,
                "carousel_type": carousel.type,
                "title": carousel.title,
                "media_type": carousel.mediaType?.rawValue ?? "mixed",
                "filters_json": try RepositoryCoding.jsonString(filters),
                "position": carousel.position,
                "cached_at": RepositoryCoding.string(from: carousel.cachedAt),
                "expires_at": RepositoryCoding.string(from: carousel.expiresAt),
                "updated_at": RepositoryCoding.string(from: now)
            ]])

            let itemRows = try carousel.items.enumerated().map { index, movie in
                [
                    "id": "\(carouselId)-\(movie.id)",
                    "carousel_id": carouselId,
                    "tmdb_id": movie.id,
                    "media_type": MediaType.movie.rawValue,
                    "position": index,
                    "payload_json": try RepositoryCoding.jsonString(movie),
                    "created_at": RepositoryCoding.string(from: now),
                    "updated_at": RepositoryCoding.string(from: now)
                ] as [String: Any]
            }
            try await db.upsert(table: "discovery_carousel_items", rows: itemRows)
        }
    }

    func invalidateCarousels(for userId: String) async throws {
        db.execute(
            "UPDATE discovery_carousels SET expires_at = ? WHERE user_id = ?",
            parameters: [RepositoryCoding.string(from: .distantPast), userId]
        )
    }

    func recordInteraction(_ interaction: DiscoveryInteraction) async throws {
        _ = try await db.insert("user_discovery_interactions", values: [
            "id": UUID().uuidString,
            "user_id": interaction.userId,
            "device_id": InstallIDService.getOrCreateInstallId(),
            "media_id": interaction.identifier.id,
            "media_type": interaction.identifier.mediaType.rawValue,
            "carousel_type": interaction.carouselType,
            "interaction_type": interaction.interactionType,
            "interacted_at": RepositoryCoding.string(from: interaction.occurredAt)
        ])
    }

    private func cachedCarousels(for userId: String) async throws -> [DiscoveryCarouselSnapshot] {
        let carouselRows = try await db.queryRaw("""
            SELECT * FROM discovery_carousels
            WHERE user_id = ? AND deleted_at IS NULL
            ORDER BY position ASC
        """, parameters: [userId])
        guard !carouselRows.isEmpty else { return [] }

        let carouselIds = carouselRows.compactMap { $0["id"] as? String }
        let placeholders = carouselIds.map { _ in "?" }.joined(separator: ",")
        let itemRows = try await db.queryRaw("""
            SELECT * FROM discovery_carousel_items
            WHERE carousel_id IN (\(placeholders)) AND deleted_at IS NULL
            ORDER BY carousel_id ASC, position ASC
        """, parameters: carouselIds)

        var itemsByCarousel: [String: [Movie]] = [:]
        for row in itemRows {
            guard let carouselId = row["carousel_id"] as? String,
                  let payload = row["payload_json"] as? String,
                  let movie = try? RepositoryCoding.decode(Movie.self, from: payload) else { continue }
            itemsByCarousel[carouselId, default: []].append(movie)
        }

        return carouselRows.compactMap { row in
            guard let id = row["id"] as? String,
                  let type = row["carousel_type"] as? String,
                  let title = row["title"] as? String,
                  let position = row["position"] as? Int,
                  let cachedAt = RepositoryCoding.date(from: row["cached_at"]),
                  let expiresAt = RepositoryCoding.date(from: row["expires_at"]) else {
                return nil
            }

            return DiscoveryCarouselSnapshot(
                type: type,
                title: title,
                mediaType: MediaType(rawValue: row["media_type"] as? String ?? ""),
                position: position,
                items: itemsByCarousel[id] ?? [],
                cachedAt: cachedAt,
                expiresAt: expiresAt
            )
        }
    }

    private func normalizePositions(_ carousels: [DiscoveryCarouselSnapshot], cachedAt: Date) -> [DiscoveryCarouselSnapshot] {
        let sorted = carousels.sorted { lhs, rhs in
            if lhs.type == "daily_mix" { return true }
            if rhs.type == "daily_mix" { return false }
            return lhs.position < rhs.position
        }

        return sorted.enumerated().map { index, carousel in
            DiscoveryCarouselSnapshot(
                type: carousel.type,
                title: carousel.title,
                mediaType: carousel.mediaType,
                position: index,
                items: carousel.items,
                cachedAt: cachedAt,
                expiresAt: cachedAt.addingTimeInterval(cacheTTL)
            )
        }
    }

    private func carouselId(userId: String, type: String, mediaType: MediaType?) -> String {
        "\(userId)-\(type)-\(mediaType?.rawValue ?? "mixed")"
    }
}
