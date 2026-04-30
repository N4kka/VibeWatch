import Foundation
import BackgroundTasks
import UIKit
import UserNotifications
import os.log

/// Manages background task scheduling for smart notifications
/// Runs every 6 hours to check for new content and schedule notifications
@MainActor
final class NotificationBackgroundTask {
    static let shared = NotificationBackgroundTask()

    // MARK: - Constants

    static let identifier = "com.vibewatch.smart-notifications"
    private static let unifiedLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vibewatch.VibeWatchApp",
        category: "NotificationBackgroundTask"
    )
    private let refreshInterval: TimeInterval = 6 * 60 * 60 // 6 hours

    // MARK: - Dependencies

    private let notificationService = SmartNotificationService.shared
    private let authService = AuthService.shared
    private let sqliteService = SQLiteService.shared
    private let notificationRepository: any NotificationRepository = LiveNotificationRepository()
    private let notificationCenter = UNUserNotificationCenter.current()

    // MARK: - Initialization

    private init() {
        Logger.info("[NotificationBackgroundTask] Initialized")
    }

    // MARK: - Registration

    /// Register the background task with the system
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: DispatchQueue.main
        ) { task in
            os_log("Background task started", log: Self.unifiedLog, type: .info)
            Logger.info("[NotificationBackgroundTask] Background task started")
            guard let refreshTask = task as? BGAppRefreshTask else {
                os_log("Unexpected task type", log: Self.unifiedLog, type: .error)
                Logger.error("[NotificationBackgroundTask] ❌ Unexpected task type: \(type(of: task))")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundTask(task: refreshTask)
        }

        os_log("Registered task %{public}@", log: Self.unifiedLog, type: .info, Self.identifier)
        Logger.info("[NotificationBackgroundTask] Registered with identifier: \(Self.identifier)")
    }

    // MARK: - Scheduling

    /// Schedule the next background refresh
    func scheduleNextRun() {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)

        // Schedule 6 hours from now
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            os_log("Scheduled next run in 6 hours", log: Self.unifiedLog, type: .info)
            Logger.info("[NotificationBackgroundTask] ✅ Scheduled next run in 6 hours")
        } catch {
            os_log("Failed to schedule: %{public}@", log: Self.unifiedLog, type: .error, String(describing: error))
            Logger.error("[NotificationBackgroundTask] ❌ Failed to schedule", error: error)
        }
    }

    /// Cancel all pending background tasks
    func cancelAllTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        Logger.info("[NotificationBackgroundTask] Cancelled all pending tasks")
    }

    // MARK: - Task Handling

    private func handleBackgroundTask(task: BGAppRefreshTask) {
        // Schedule next run immediately
        scheduleNextRun()

        // Set up expiration handler
        task.expirationHandler = {
            Logger.warning("[NotificationBackgroundTask] ⏰ Task expired before completion")
            task.setTaskCompleted(success: false)
        }

        // Execute notification check in background
        Task {
            do {
                guard let userId = authService.currentUser?.id else {
                    os_log("No user logged in", log: Self.unifiedLog, type: .info)
                    Logger.warning("[NotificationBackgroundTask] No user logged in")
                    task.setTaskCompleted(success: true)
                    return
                }

                os_log("Processing notifications", log: Self.unifiedLog, type: .info)
                Logger.info("[NotificationBackgroundTask] Processing notifications for user: \(userId)")

                // Check permission status
                await notificationService.checkPermissionStatus()

                guard notificationService.notificationPermissionGranted else {
                    os_log("Notifications not permitted", log: Self.unifiedLog, type: .info)
                    Logger.warning("[NotificationBackgroundTask] Notifications not permitted")
                    task.setTaskCompleted(success: true)
                    return
                }

                try await scheduleLocalDigestNotifications(userId: userId)

                os_log("Background task completed successfully", log: Self.unifiedLog, type: .info)
                Logger.info("[NotificationBackgroundTask] ✅ Background task completed successfully")
                task.setTaskCompleted(success: true)

            } catch {
                os_log("Task failed: %{public}@", log: Self.unifiedLog, type: .error, String(describing: error))
                Logger.error("[NotificationBackgroundTask] ❌ Task failed", error: error)
                task.setTaskCompleted(success: false)
            }
        }
    }

    // MARK: - Manual Trigger (for testing)

    /// Manually trigger notification check (for development/testing)
    func triggerImmediately() async {
        guard let userId = authService.currentUser?.id else {
            Logger.warning("[NotificationBackgroundTask] No user logged in")
            return
        }

        Logger.info("[NotificationBackgroundTask] Manual trigger - checking notifications")

        await notificationService.checkPermissionStatus()

        guard notificationService.notificationPermissionGranted else {
            Logger.warning("[NotificationBackgroundTask] Notifications not permitted")
            return
        }

        do {
            try await scheduleLocalDigestNotifications(userId: userId)
        } catch {
            Logger.error("[NotificationBackgroundTask] Manual trigger failed", error: error)
        }

        Logger.info("[NotificationBackgroundTask] Manual trigger complete")
    }

    // MARK: - Local Digest

    private func scheduleLocalDigestNotifications(userId: String) async throws {
        let candidates = try await loadLocalDigestCandidates(userId: userId)
        guard !candidates.isEmpty else {
            os_log("No local digest candidates", log: Self.unifiedLog, type: .info)
            Logger.info("[NotificationBackgroundTask] No local digest candidates")
            return
        }

        var scheduledCount = 0
        for candidate in candidates.prefix(3) {
            let eventKey = "local_digest:\(candidate.mediaType.rawValue):\(candidate.mediaId):\(candidate.region)"
            let alreadySent = try await notificationRepository.wasAlreadySent(eventKey: eventKey, channel: .localDigest, userId: userId)
            guard !alreadySent else {
                continue
            }

            let scheduledFor = nextDigestDeliveryDate()
            let event = notificationEvent(
                userId: userId,
                eventKey: eventKey,
                candidate: candidate,
                scheduledFor: scheduledFor
            )

            try await scheduleCalendarNotification(for: event)
            try await notificationRepository.recordScheduled(event)
            scheduledCount += 1
        }

        os_log("Scheduled %{public}d local digest notifications", log: Self.unifiedLog, type: .info, scheduledCount)
        Logger.info("[NotificationBackgroundTask] Scheduled \(scheduledCount) local digest notifications")
    }

    private func loadLocalDigestCandidates(userId: String) async throws -> [LocalDigestCandidate] {
        let now = RepositoryCoding.string(from: Date())
        let rows = try await sqliteService.queryRaw("""
            SELECT li.media_id, li.media_type, li.title, ma.region, ma.providers_json
            FROM list_items li
            JOIN lists l ON l.id = li.list_id AND l.user_id = li.user_id
            JOIN media_availability ma ON ma.tmdb_id = li.media_id AND ma.media_type = li.media_type
            WHERE li.user_id = ?
              AND l.type = ?
              AND li.deleted_at IS NULL
              AND l.deleted_at IS NULL
              AND ma.deleted_at IS NULL
              AND ma.expires_at > ?
              AND ma.providers_json IS NOT NULL
              AND ma.providers_json != ''
              AND ma.providers_json != '{}'
            ORDER BY li.added_at DESC
            LIMIT 5
        """, parameters: [userId, ListType.watchlist.rawValue, now])

        return rows.compactMap { row in
            guard let mediaId = row["media_id"] as? Int,
                  let mediaTypeRaw = row["media_type"] as? String,
                  let mediaType = MediaType(rawValue: mediaTypeRaw),
                  let title = row["title"] as? String,
                  let region = row["region"] as? String else {
                return nil
            }

            return LocalDigestCandidate(
                mediaId: mediaId,
                mediaType: mediaType,
                title: title,
                region: region
            )
        }
    }

    private func notificationEvent(
        userId: String,
        eventKey: String,
        candidate: LocalDigestCandidate,
        scheduledFor: Date
    ) -> NotificationEvent {
        let now = Date()
        return NotificationEvent(
            id: eventKey,
            userId: userId,
            eventKey: eventKey,
            channel: .localDigest,
            notificationType: .watchlistAlert,
            mediaId: candidate.mediaId,
            mediaType: candidate.mediaType,
            title: "Watchlist Update",
            body: "\(candidate.title) has saved availability data ready to check.",
            scheduledFor: scheduledFor,
            sentAt: nil,
            openedAt: nil,
            dismissedAt: nil,
            payload: [
                "media_id": String(candidate.mediaId),
                "media_type": candidate.mediaType.rawValue,
                "region": candidate.region
            ],
            createdAt: now,
            updatedAt: now
        )
    }

    private func scheduleCalendarNotification(for event: NotificationEvent) async throws {
        guard let scheduledFor = event.scheduledFor else { return }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.userInfo = event.payload.merging([
            "type": event.notificationType.rawValue,
            "event_id": event.id
        ]) { current, _ in current }

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledFor)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: trigger)

        try await notificationCenter.add(request)
    }

    private func nextDigestDeliveryDate(from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        if let today = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date), today > date {
            return today
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(24 * 60 * 60)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

private struct LocalDigestCandidate {
    let mediaId: Int
    let mediaType: MediaType
    let title: String
    let region: String
}
