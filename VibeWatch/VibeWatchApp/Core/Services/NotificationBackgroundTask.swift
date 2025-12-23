import Foundation
import BackgroundTasks
import UIKit

/// Manages background task scheduling for smart notifications
/// Runs every 6 hours to check for new content and schedule notifications
class NotificationBackgroundTask {
    static let shared = NotificationBackgroundTask()

    // MARK: - Constants

    static let identifier = "com.vibewatch.smart-notifications"
    private let refreshInterval: TimeInterval = 6 * 60 * 60 // 6 hours

    // MARK: - Dependencies

    private let notificationService = SmartNotificationService.shared
    private let authService = AuthService.shared

    // MARK: - Initialization

    private init() {
        Logger.info("[NotificationBackgroundTask] Initialized")
    }

    // MARK: - Registration

    /// Register the background task with the system
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: nil
        ) { task in
            Logger.info("[NotificationBackgroundTask] Background task started")
            self.handleBackgroundTask(task: task as! BGAppRefreshTask)
        }

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
            Logger.info("[NotificationBackgroundTask] ✅ Scheduled next run in 6 hours")
        } catch {
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
                guard let userId = await authService.currentUser?.id else {
                    Logger.warning("[NotificationBackgroundTask] No user logged in")
                    task.setTaskCompleted(success: true)
                    return
                }

                Logger.info("[NotificationBackgroundTask] Processing notifications for user: \(userId)")

                // Check permission status
                await notificationService.checkPermissionStatus()

                guard await notificationService.notificationPermissionGranted else {
                    Logger.warning("[NotificationBackgroundTask] Notifications not permitted")
                    task.setTaskCompleted(success: true)
                    return
                }

                // Load user preferences
                await notificationService.loadPreferences(userId: userId)

                // Schedule personalized notifications
                await notificationService.schedulePersonalizedNotifications(userId: userId)

                Logger.info("[NotificationBackgroundTask] ✅ Background task completed successfully")
                task.setTaskCompleted(success: true)

            } catch {
                Logger.error("[NotificationBackgroundTask] ❌ Task failed", error: error)
                task.setTaskCompleted(success: false)
            }
        }
    }

    // MARK: - Manual Trigger (for testing)

    /// Manually trigger notification check (for development/testing)
    func triggerImmediately() async {
        guard let userId = await authService.currentUser?.id else {
            Logger.warning("[NotificationBackgroundTask] No user logged in")
            return
        }

        Logger.info("[NotificationBackgroundTask] Manual trigger - checking notifications")

        await notificationService.checkPermissionStatus()

        guard await notificationService.notificationPermissionGranted else {
            Logger.warning("[NotificationBackgroundTask] Notifications not permitted")
            return
        }

        await notificationService.loadPreferences(userId: userId)
        await notificationService.schedulePersonalizedNotifications(userId: userId)

        Logger.info("[NotificationBackgroundTask] Manual trigger complete")
    }
}
