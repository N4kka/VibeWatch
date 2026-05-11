import Foundation

@MainActor
final class LiveNotificationRepository: NotificationRepositoryProtocol {
    static let shared = LiveNotificationRepository()
    private init() {}

    func toggleAlert(mediaId: Int, mediaType: MediaType, enabled: Bool = true) async throws {
        guard let userId = AuthService.shared.currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }

        let region = Locale.current.region?.identifier ?? "US"
        let now = ISO8601DateFormatter().string(from: Date())
        let record: [String: Any] = [
            "user_id": userId,
            "media_id": mediaId,
            "media_type": mediaType.rawValue,
            "source": "notify_me",
            "country_code": region,
            "is_active": enabled,
            "updated_at": now
        ]

        try await SupabaseService.shared.upsertRow(
            table: "release_alerts",
            onConflict: "user_id,media_id,media_type",
            record: record
        )
    }
}
