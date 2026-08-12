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
    private var tokenObserver: NSObjectProtocol?

    private init() {
        Task {
            await refreshAuthorizationStatus()
        }
        // Observe FCM token refresh events so we re-register whenever the token rotates
        tokenObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("FIRMessagingRegistrationTokenRefreshNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerDeviceToken()
        }
    }

    /// Registers the device's current FCM token with the backend.
    /// Safe to call even before the APNs token is available — FCM will
    /// queue the fetch internally and deliver via MessagingDelegate instead.
    func registerDeviceToken() {
        Messaging.messaging().token { token, error in
            if let error = error {
                Logger.error("[NotificationService] Error fetching FCM token: \(error)")
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
        let granted = await requestAuthorizationDecision()
        await completeNotificationEnablement(afterAuthorization: granted)
        return granted
    }

    /// Returns as soon as the native authorization popup has produced a decision.
    /// Onboarding uses this boundary to advance immediately.
    func requestAuthorizationDecision() async -> Bool {
        await requestAuthorization()
    }

    /// Finishes the non-UI work that follows the native authorization decision.
    func completeNotificationEnablement(afterAuthorization granted: Bool) async {
        await refreshAuthorizationStatus()

        if granted {
            await registerForRemoteNotifications()
            // Upsert the user's prefs row so the backend knows push is enabled
            let prefs = NotificationPreferencesView.loadFromDefaults()
            await syncPreferencesToSupabase(prefs)
        }
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

    func refreshAuthorizationStatus() async {
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

    // MARK: - Preferences sync

    /// Upserts the user's notification preferences to Supabase so the backend
    /// (process-notifications) can honour them when delivering push messages.
    func syncPreferencesToSupabase(_ prefs: NotificationPreferences) async {
        guard let userId = AuthService.shared.currentUser?.id else {
            Logger.debug("[NotificationService] Not logged in, skipping prefs sync.")
            return
        }

        struct PrefsPayload: Encodable {
            let user_id: String
            let push_enabled: Bool
            let new_availability: Bool
            let new_release: Bool
            let episode_aired: Bool
            let continue_watching: Bool
            let list_milestone: Bool
            let price_drop: Bool
            let streak_reminder: Bool
            let quiet_hours_start: String
            let quiet_hours_end: String
            let timezone: String
            let updated_at: String
        }

        let payload = PrefsPayload(
            user_id:           userId,
            push_enabled:      notificationsEnabled,
            new_availability:  prefs.enableNewAvailability,
            new_release:       prefs.enableNewRelease,
            episode_aired:     prefs.enableEpisodeAired,
            continue_watching: prefs.enableContinueWatching,
            list_milestone:    prefs.enableListMilestone,
            price_drop:        false,
            streak_reminder:   false,
            quiet_hours_start: String(format: "%02d:00:00", prefs.quietHoursStart),
            quiet_hours_end:   String(format: "%02d:00:00", prefs.quietHoursEnd),
            timezone:          TimeZone.current.identifier,
            updated_at:        ISO8601DateFormatter().string(from: Date())
        )

        do {
            try await SupabaseService.shared.client?
                .from("user_notification_preferences")
                .upsert(payload, onConflict: "user_id")
                .execute()
            Logger.info("[NotificationService] Notification preferences synced to Supabase.")
        } catch {
            Logger.error("[NotificationService] Failed to sync prefs: \(error.localizedDescription)")
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
