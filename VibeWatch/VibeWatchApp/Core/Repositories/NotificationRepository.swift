import Foundation

enum NotificationChannel: String, Codable {
    case localReminder = "local_reminder"
    case localDigest = "local_digest"
    case remotePush = "remote_push"
}

struct NotificationEvent: Identifiable, Codable {
    let id: String
    let userId: String
    let eventKey: String
    let channel: NotificationChannel
    let notificationType: NotificationType
    let mediaId: Int?
    let mediaType: MediaType?
    let title: String
    let body: String
    let scheduledFor: Date?
    let sentAt: Date?
    let openedAt: Date?
    let dismissedAt: Date?
    let payload: [String: String]
    let createdAt: Date
    let updatedAt: Date
}

@MainActor
protocol NotificationRepository: AnyObject, Sendable {
    func events(for userId: String) -> AsyncStream<[NotificationEvent]>
    func wasAlreadySent(eventKey: String, channel: NotificationChannel, userId: String) async throws -> Bool

    func recordScheduled(_ event: NotificationEvent) async throws
    func recordSent(eventId: String, sentAt: Date) async throws
    func recordOpened(eventId: String, openedAt: Date) async throws
    func recordDismissed(eventId: String, dismissedAt: Date) async throws

    // MARK: - APNs Device Token (Phase 8)

    /// Registers or updates the raw APNs device token (hex-encoded) for the current user on Supabase.
    /// Also stores the token locally in `device_tokens` for offline reference.
    func registerAPNsDeviceToken(_ tokenHex: String, userId: String) async throws
}
