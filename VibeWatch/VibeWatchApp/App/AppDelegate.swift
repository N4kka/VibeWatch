import UIKit
import Supabase
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate, @MainActor MessagingDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        DiscoveryCarouselBackgroundRefresher.shared.register()
        DiscoveryCarouselBackgroundRefresher.shared.scheduleNextRefresh()
        CerebrasBackendBackgroundScheduler.shared.register()
        CerebrasBackendBackgroundScheduler.shared.scheduleNextRun()
        NotificationBackgroundTask.shared.register()
        NotificationBackgroundTask.shared.scheduleNextRun()
        UserPreferenceManager.shared.setSyncManager(SyncManager.shared)

        // Initialize Firebase
        FirebaseApp.configure() // Call FirebaseApp.configure() here
        
        // Initialize LocalizationManager early to ensure translations are loaded before UI
        _ = LocalizationManager.shared
        print("✅ LocalizationManager initialized: \(LocalizationManager.shared.currentLanguage.name)")
        
        // Configure Firebase Messaging and User Notifications
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
        
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions,
            completionHandler: { _, _ in }
        )
        
        application.registerForRemoteNotifications()
        
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        DiscoveryCarouselBackgroundRefresher.shared.scheduleNextRefresh()
        CerebrasBackendBackgroundScheduler.shared.scheduleNextRun()
        NotificationBackgroundTask.shared.scheduleNextRun()
    }
    
    // Handle URL schemes (for OAuth callbacks)
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        print("📱 Received URL: \(url.absoluteString)")
        
        let validSchemes = [
            "com.vibewatch.VibeWatchApp",
            "com.vibewatch.VibeWatchApp.beta",
            "com.vibewatch.vibewatchapp",
            "com.vibewatch.vibewatchapp.beta"
        ]
        
        // Handle Supabase OAuth callback
        if let scheme = url.scheme, validSchemes.contains(scheme) && url.host == "auth" {
            Task {
                do {
                    try await AuthService.shared.handleAuthCallback(url: url)
                    print("✅ Auth callback handled successfully")
                } catch {
                    print("❌ Error handling OAuth callback: \(error.localizedDescription)")
                }
            }
            return true
        }
        
        return false
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    // Receive displayed notifications for iOS 10 devices.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        
        // With swizzling disabled you must let Message know there's a message here.
        // Messaging.messaging().appDidReceiveMessage(userInfo)
        
        // Print message ID.
        if let messageID = userInfo["gcm.message_id"] {
            print("Message ID: \(messageID)")
        }
        
        // Print full message.
        print(userInfo)
        
        // Change this to your preferred presentation option
        completionHandler([[.banner, .sound]])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        // Print message ID.
        if let messageID = userInfo["gcm.message_id"] {
            print("Message ID: \(messageID)")
        }
        
        // Print full message.
        print(userInfo)
        
        // Handle deep link if present
        AppNavigationManager.shared.handle(userInfo: userInfo)
        
        completionHandler()
    }
    
    // MARK: - MessagingDelegate
    
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("Firebase registration token: \(String(describing: fcmToken))")
        
        NotificationService.shared.processNewFCMToken(fcmToken)
    }
    
    // MARK: - APNs Delegate
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("APNs token received: \(deviceToken.description)")
        Messaging.messaging().apnsToken = deviceToken
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Unable to register for remote notifications: \(error.localizedDescription)")
    }
}
