import Foundation

@MainActor
final class LiveNotificationRepository: NotificationRepository {
    private let db: SQLiteService

    init(db: SQLiteService = .shared) {
        self.db = db
    }

    func events(for userId: String) -> AsyncStream<[NotificationEvent]> {
        AsyncStream { continuation in
            Task { @MainActor in
                continuation.yield((try? await loadEvents(for: userId)) ?? [])
                continuation.finish()
            }
        }
    }

    func wasAlreadySent(eventKey: String, channel: NotificationChannel, userId: String) async throws -> Bool {
        let rows = try await db.queryRaw("""
            SELECT id FROM notification_events
            WHERE user_id = ? AND event_key = ? AND channel = ? AND sent_at IS NOT NULL
            LIMIT 1
        """, parameters: [userId, eventKey, channel.rawValue])
        return !rows.isEmpty
    }

    func recordScheduled(_ event: NotificationEvent) async throws {
        try await db.upsert(table: "notification_events", rows: [try row(from: event)])
    }

    func recordSent(eventId: String, sentAt: Date) async throws {
        try await db.update(
            "notification_events",
            values: ["sent_at": RepositoryCoding.string(from: sentAt), "updated_at": RepositoryCoding.string(from: Date())],
            where: "id = ?",
            parameters: [eventId]
        )
    }

    func recordOpened(eventId: String, openedAt: Date) async throws {
        try await db.update(
            "notification_events",
            values: ["opened_at": RepositoryCoding.string(from: openedAt), "updated_at": RepositoryCoding.string(from: Date())],
            where: "id = ?",
            parameters: [eventId]
        )
    }

    func recordDismissed(eventId: String, dismissedAt: Date) async throws {
        try await db.update(
            "notification_events",
            values: ["dismissed_at": RepositoryCoding.string(from: dismissedAt), "updated_at": RepositoryCoding.string(from: Date())],
            where: "id = ?",
            parameters: [eventId]
        )
    }

    private func loadEvents(for userId: String) async throws -> [NotificationEvent] {
        let rows = try await db.queryRaw("""
            SELECT * FROM notification_events
            WHERE user_id = ?
            ORDER BY created_at DESC
        """, parameters: [userId])
        return rows.compactMap(event(from:))
    }

    private func row(from event: NotificationEvent) throws -> [String: Any] {
        [
            "id": event.id,
            "user_id": event.userId,
            "event_key": event.eventKey,
            "channel": event.channel.rawValue,
            "notification_type": event.notificationType.rawValue,
            "media_id": event.mediaId ?? NSNull(),
            "media_type": event.mediaType?.rawValue ?? NSNull(),
            "title": event.title,
            "body": event.body,
            "scheduled_for": event.scheduledFor.map(RepositoryCoding.string(from:)) ?? NSNull(),
            "sent_at": event.sentAt.map(RepositoryCoding.string(from:)) ?? NSNull(),
            "opened_at": event.openedAt.map(RepositoryCoding.string(from:)) ?? NSNull(),
            "dismissed_at": event.dismissedAt.map(RepositoryCoding.string(from:)) ?? NSNull(),
            "payload_json": try RepositoryCoding.jsonString(event.payload),
            "created_at": RepositoryCoding.string(from: event.createdAt),
            "updated_at": RepositoryCoding.string(from: event.updatedAt)
        ]
    }

    // MARK: - APNs Device Token (Phase 8)

    func registerAPNsDeviceToken(_ tokenHex: String, userId: String) async throws {
        let now = RepositoryCoding.string(from: Date())
        let locale = Locale.current.identifier
        let timezone = TimeZone.current.identifier

        // 1. Store locally in SQLite for offline reference
        try await db.upsert(table: "device_tokens", rows: [[
            "user_id": userId,
            "token": tokenHex,
            "platform": "ios",
            "locale": locale,
            "timezone": timezone,
            "created_at": now,
            "last_seen_at": now
        ]])

        // 2. Upsert to Supabase using the SDK
        guard let client = AuthService.shared.client else {
            Logger.warning("[LiveNotificationRepository] Supabase client unavailable, token stored locally only")
            return
        }

        struct DeviceTokenUpsert: Encodable {
            let user_id: String
            let token: String
            let platform: String
            let locale: String
            let timezone: String
            let last_seen_at: String
        }

        let payload = DeviceTokenUpsert(
            user_id: userId,
            token: tokenHex,
            platform: "ios",
            locale: locale,
            timezone: timezone,
            last_seen_at: ISO8601DateFormatter().string(from: Date())
        )

        do {
            try await client
                .from("device_tokens")
                .upsert(payload)
                .execute()
            Logger.info("[LiveNotificationRepository] APNs token upserted to Supabase for user \(userId.prefix(8))...")
        } catch {
            Logger.warning("[LiveNotificationRepository] Failed to upsert APNs token remotely: \(error.localizedDescription)")
            // Not thrown — the local store succeeded, so the token will sync on next opportunity
        }
    }

    private func event(from row: [String: Any]) -> NotificationEvent? {
        guard let id = row["id"] as? String,
              let userId = row["user_id"] as? String,
              let eventKey = row["event_key"] as? String,
              let channelRaw = row["channel"] as? String,
              let channel = NotificationChannel(rawValue: channelRaw),
              let notificationTypeRaw = row["notification_type"] as? String,
              let notificationType = NotificationType(rawValue: notificationTypeRaw),
              let title = row["title"] as? String,
              let body = row["body"] as? String,
              let createdAt = RepositoryCoding.date(from: row["created_at"]),
              let updatedAt = RepositoryCoding.date(from: row["updated_at"]) else {
            return nil
        }

        let payloadJSON = row["payload_json"] as? String ?? "{}"
        let payload = (try? RepositoryCoding.decode([String: String].self, from: payloadJSON)) ?? [:]

        return NotificationEvent(
            id: id,
            userId: userId,
            eventKey: eventKey,
            channel: channel,
            notificationType: notificationType,
            mediaId: row["media_id"] as? Int,
            mediaType: MediaType(rawValue: row["media_type"] as? String ?? ""),
            title: title,
            body: body,
            scheduledFor: RepositoryCoding.date(from: row["scheduled_for"]),
            sentAt: RepositoryCoding.date(from: row["sent_at"]),
            openedAt: RepositoryCoding.date(from: row["opened_at"]),
            dismissedAt: RepositoryCoding.date(from: row["dismissed_at"]),
            payload: payload,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
