import UIKit
import Supabase
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import BackgroundTasks
import GoogleMobileAds

class AppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate, @MainActor MessagingDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        DiscoveryCarouselBackgroundRefresher.shared.register()
        DiscoveryCarouselBackgroundRefresher.shared.scheduleNextRefresh()
        CerebrasBackendBackgroundScheduler.shared.register()
        CerebrasBackendBackgroundScheduler.shared.scheduleNextRun()
        UserPreferenceManager.shared.setSyncEngine(SyncEngine.shared)

        // Initialize Firebase
        FirebaseApp.configure()

        // Crash reporting (P3): Crashlytics starts with Firebase, but collection has to follow the
        // analytics opt-out, and the install id makes a crash traceable before sign-in.
        CrashReportingService.start(
            isEnabled: UserDefaults.standard.object(forKey: "analytics.isEnabled") as? Bool ?? true,
            installId: InstallIDService.getOrCreateInstallId()
        )

        // Initialize Google Mobile Ads SDK
        MobileAds.shared.start(completionHandler: nil)

        // Initialize LocalizationManager early to ensure translations are loaded before UI
        _ = LocalizationManager.shared
        Logger.info("[AppDelegate] LocalizationManager initialized: \(LocalizationManager.shared.currentLanguage.name)")

        // Configure Firebase Messaging — AppDelegate is the sole UNUserNotificationCenterDelegate
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self

        // Register for APNs so FCM can obtain a token; authorization prompt is shown
        // only when the user enables notifications from ProfileView.
        application.registerForRemoteNotifications()

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        DiscoveryCarouselBackgroundRefresher.shared.scheduleNextRefresh()
        CerebrasBackendBackgroundScheduler.shared.scheduleNextRun()
    }
    
    // Handle URL schemes (for OAuth callbacks)
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        Logger.info("[AppDelegate] Received URL: \(url.absoluteString)")
        
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
                    Logger.info("[AppDelegate] Auth callback handled successfully")
                } catch {
                    Logger.error("[AppDelegate] Error handling OAuth callback: \(error.localizedDescription)")
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
            Logger.debug("[AppDelegate] Message ID: \(messageID)")
        }

        // Print full message.
        Logger.debug("[AppDelegate] willPresent notification userInfo: \(userInfo)")

        // Change this to your preferred presentation option
        completionHandler([[.banner, .sound, .badge, .list]])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        // Print message ID.
        if let messageID = userInfo["gcm.message_id"] {
            Logger.debug("[AppDelegate] Message ID: \(messageID)")
        }

        // Print full message.
        Logger.debug("[AppDelegate] didReceive notification userInfo: \(userInfo)")

        // Handle deep link if present
        AppNavigationManager.shared.handle(userInfo: userInfo)
        
        completionHandler()
    }
    
    // MARK: - MessagingDelegate
    
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Logger.info("[AppDelegate] Firebase registration token: \(String(describing: fcmToken))")
        
        NotificationService.shared.processNewFCMToken(fcmToken)
    }
    
    // MARK: - APNs Delegate
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Logger.info("[AppDelegate] APNs token received: \(deviceToken.description)")
        Messaging.messaging().apnsToken = deviceToken
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.error("[AppDelegate] Unable to register for remote notifications: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Logger.debug("[AppDelegate] didReceiveRemoteNotification userInfo: \(userInfo)")

        Task {
            if let userId = AuthService.shared.currentUser?.id {
                await GamificationService.shared.syncFromSupabase(userId: userId)
            }
            completionHandler(.newData)
        }
    }
}
