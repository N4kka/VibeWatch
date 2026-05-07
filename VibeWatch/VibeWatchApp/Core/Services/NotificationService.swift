import Foundation
import FirebaseMessaging
import Combine
import UserNotifications
import UIKit

@MainActor
class NotificationService: ObservableObject { // Conform to ObservableObject
    static let shared = NotificationService()

    @Published var notificationsEnabled: Bool = false
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var cachedFCMToken: String?
    
    private init() {
        Task {
            await refreshAuthorizationStatus()
        }
    }
    
    /// Registers the device's current FCM token with the backend database.
    /// This function should be called after a user successfully logs in
    /// and whenever the FCM token is refreshed.
    func registerDeviceToken() {
        guard Messaging.messaging().apnsToken != nil else {
            Logger.debug("[NotificationService] APNS token missing, skipping FCM fetch until available.")
            return
        }

        Messaging.messaging().token { token, error in
            if let error = error {
                Logger.error("[NotificationService] Error fetching FCM registration token: \(error)")
                return
            }

            Task { @MainActor in
                self.processNewFCMToken(token)
            }
        }
    }

    func processNewFCMToken(_ token: String?) {
        guard let token = token else {
            Logger.debug("[NotificationService] Received nil FCM token.")
            return
        }

        cachedFCMToken = token
        Logger.debug("[NotificationService] Cached FCM token: \(token)")

        Task {
            await registerCachedTokenIfPossible()
        }
    }

    func enableNotifications() async -> Bool {
        let granted = await requestAuthorization()
        await refreshAuthorizationStatus()

        if granted {
            await registerForRemoteNotifications()
        }

        return granted
    }

    func disableNotifications() async {
        notificationsEnabled = false
        await unregisterForRemoteNotifications()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshAuthorizationStatus() async {
        let settings = await fetchNotificationSettings()
        authorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationsEnabled = true
        default:
            notificationsEnabled = false
        }
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func fetchNotificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func registerForRemoteNotifications() async {
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
        registerDeviceToken()
    }

    private func unregisterForRemoteNotifications() async {
        await MainActor.run {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }

    private func registerCachedTokenIfPossible() async {
        guard let token = cachedFCMToken else {
            Logger.debug("[NotificationService] No cached FCM token to register yet.")
            return
        }

        guard let userId = AuthService.shared.currentUser?.id else {
            Logger.debug("[NotificationService] User not logged in, deferring token registration.")
            return
        }

        do {
            Logger.debug("[NotificationService] Registering cached token for user \(userId)")
            try await AuthService.shared.upsertDeviceToken(token, platform: "ios")
            Logger.debug("[NotificationService] FCM token saved/updated successfully.")
        } catch {
            Logger.error("[NotificationService] Error saving FCM token to database: \(error.localizedDescription)")
        }
    }
}

// UNNotificationSettings is value-like but not marked Sendable.
extension UNNotificationSettings: @unchecked @retroactive Sendable {}
