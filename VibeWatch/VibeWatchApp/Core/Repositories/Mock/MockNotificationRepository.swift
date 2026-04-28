import Foundation

@MainActor
final class MockNotificationRepository: NotificationRepository {
    var eventsByUser: [String: [NotificationEvent]] = [:]

    func events(for userId: String) -> AsyncStream<[NotificationEvent]> {
        AsyncStream { continuation in
            continuation.yield(eventsByUser[userId] ?? [])
            continuation.finish()
        }
    }

    func wasAlreadySent(eventKey: String, channel: NotificationChannel, userId: String) async throws -> Bool {
        (eventsByUser[userId] ?? []).contains {
            $0.eventKey == eventKey && $0.channel == channel && $0.sentAt != nil
        }
    }

    func recordScheduled(_ event: NotificationEvent) async throws {
        eventsByUser[event.userId, default: []].append(event)
    }

    func recordSent(eventId: String, sentAt: Date) async throws {
        update(eventId: eventId) { event in
            NotificationEvent(
                id: event.id,
                userId: event.userId,
                eventKey: event.eventKey,
                channel: event.channel,
                notificationType: event.notificationType,
                mediaId: event.mediaId,
                mediaType: event.mediaType,
                title: event.title,
                body: event.body,
                scheduledFor: event.scheduledFor,
                sentAt: sentAt,
                openedAt: event.openedAt,
                dismissedAt: event.dismissedAt,
                payload: event.payload,
                createdAt: event.createdAt,
                updatedAt: Date()
            )
        }
    }

    func recordOpened(eventId: String, openedAt: Date) async throws {}
    func recordDismissed(eventId: String, dismissedAt: Date) async throws {}

    private func update(eventId: String, transform: (NotificationEvent) -> NotificationEvent) {
        for userId in eventsByUser.keys {
            guard let index = eventsByUser[userId]?.firstIndex(where: { $0.id == eventId }),
                  let event = eventsByUser[userId]?[index] else { continue }
            eventsByUser[userId]?[index] = transform(event)
            return
        }
    }
}
