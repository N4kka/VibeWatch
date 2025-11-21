import Foundation
import UserNotifications
import UIKit

@MainActor
class NotificationService: ObservableObject {
    static let shared = NotificationService()
    
    @Published var isAuthorized = false
    @Published var notificationsEnabled = false
    
    private init() {
        Task {
            await checkAuthorizationStatus()
        }
    }
    
    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.isAuthorized = settings.authorizationStatus == .authorized
        
        // Load user's notification preference from database
        if let userId = AuthService.shared.currentUser?.id {
            await loadNotificationPreference(userId: userId)
        } else {
            // Sync with system authorization if not logged in
            self.notificationsEnabled = self.isAuthorized
        }
    }
    
    private func loadNotificationPreference(userId: String) async {
        guard let client = AuthService.shared.client else { return }
        
        do {
            let response: [UserNotificationPreference] = try await client
                .from("users")
                .select("notifications_enabled")
                .eq("id", value: userId)
                .execute()
                .value
            
            if let preference = response.first {
                self.notificationsEnabled = preference.notificationsEnabled
            } else {
                // Default to system authorization state
                self.notificationsEnabled = self.isAuthorized
            }
        } catch {
            print("❌ Error loading notification preference: \(error.localizedDescription)")
            // Fallback to system authorization state
            self.notificationsEnabled = self.isAuthorized
        }
    }
    
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            
            self.isAuthorized = granted
            
            if granted {
                print("✅ Notification permission granted")
                self.notificationsEnabled = true
                await updateNotificationPreference(enabled: true)
            } else {
                print("❌ Notification permission denied")
                self.notificationsEnabled = false
                await updateNotificationPreference(enabled: false)
            }
            
            return granted
        } catch {
            print("❌ Error requesting notification permission: \(error.localizedDescription)")
            return false
        }
    }
    
    func enableNotifications() async -> Bool {
        // Check current system authorization
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        
        switch settings.authorizationStatus {
        case .notDetermined:
            // First time - request permission
            return await requestPermission()
            
        case .denied:
            // Permission was denied - can't enable, need to go to settings
            return false
            
        case .authorized, .provisional, .ephemeral:
            // Already authorized - just enable
            self.isAuthorized = true
            self.notificationsEnabled = true
            await updateNotificationPreference(enabled: true)
            return true
            
        @unknown default:
            return false
        }
    }
    
    func disableNotifications() async {
        self.notificationsEnabled = false
        await updateNotificationPreference(enabled: false)
        print("✅ Notifications disabled")
    }
    
    private func updateNotificationPreference(enabled: Bool) async {
        guard let client = AuthService.shared.client,
              let userId = AuthService.shared.currentUser?.id else {
            return
        }
        
        do {
            try await client
                .from("users")
                .update(["notifications_enabled": enabled])
                .eq("id", value: userId)
                .execute()
            
            print("✅ Notification preference updated: \(enabled)")
        } catch {
            print("❌ Error updating notification preference: \(error.localizedDescription)")
        }
    }
    
    func openSettings() {
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        }
    }
}

// Helper struct for decoding user notification preference
struct UserNotificationPreference: Codable {
    let notificationsEnabled: Bool
    
    enum CodingKeys: String, CodingKey {
        case notificationsEnabled = "notifications_enabled"
    }
}
