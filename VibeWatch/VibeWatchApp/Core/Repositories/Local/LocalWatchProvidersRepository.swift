import Foundation

/// Reads and writes watch providers from the local `watch_providers` SQLite table.
/// Only returns cached data if within the TTL window; never touches the network.
@MainActor
final class LocalWatchProvidersRepository {
    static let shared = LocalWatchProvidersRepository()
    private let db = SQLiteService.shared
    private let ttl: TimeInterval = 24 * 60 * 60
    private let formatter = ISO8601DateFormatter()
    private init() {}

    func cachedProviders(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders? {
        let now = formatter.string(from: Date())
        guard let rows = try? await db.queryRaw("""
            SELECT providers_json FROM watch_providers
            WHERE media_id = ? AND media_type = ? AND region = ? AND expires_at > ?
        """, parameters: [mediaId, mediaType.rawValue, region, now]),
        let row = rows.first,
        let json = row["providers_json"] as? String,
        let data = Data(base64Encoded: json),
        let decoded = try? JSONDecoder().decode(CountryProviders.self, from: data)
        else { return nil }
        return decoded
    }

    func save(_ providers: CountryProviders, mediaId: Int, mediaType: MediaType, region: String) async {
        guard let json = try? JSONEncoder().encode(providers).base64EncodedString() else { return }
        let now = Date()
        let values: [String: Any] = [
            "id": "\(mediaId)-\(mediaType.rawValue)-\(region)",
            "media_id": mediaId,
            "media_type": mediaType.rawValue,
            "region": region,
            "providers_json": json,
            "refreshed_at": formatter.string(from: now),
            "expires_at": formatter.string(from: now.addingTimeInterval(ttl))
        ]
        let existing = (try? await db.queryRaw(
            "SELECT id FROM watch_providers WHERE media_id = ? AND media_type = ? AND region = ?",
            parameters: [mediaId, mediaType.rawValue, region]
        )) ?? []
        if let existingId = existing.first?["id"] as? String {
            try? await db.update("watch_providers", values: values, where: "id = ?", parameters: [existingId])
        } else {
            _ = try? await db.insert("watch_providers", values: values)
        }
    }
}
