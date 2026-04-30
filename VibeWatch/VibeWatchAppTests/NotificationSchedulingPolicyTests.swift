import XCTest

final class NotificationSchedulingPolicyTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testProductionCodeDoesNotUseTimeIntervalNotificationTriggers() throws {
        let appRoot = repositoryRoot.appendingPathComponent("VibeWatchApp")
        let swiftFiles = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        let offenders = try swiftFiles.compactMap { file -> String? in
            let contents = try String(contentsOf: file, encoding: .utf8)
            guard contents.contains("UNTimeIntervalNotificationTrigger") else { return nil }
            return file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
        }

        XCTAssertTrue(offenders.isEmpty, "Production code must not schedule local notifications with time interval triggers: \(offenders)")
    }

    func testAppLifecycleDoesNotTriggerSmartNotificationScheduling() throws {
        let appFile = repositoryRoot.appendingPathComponent("VibeWatchApp/App/VibeWatchApp.swift")
        let contents = try String(contentsOf: appFile, encoding: .utf8)

        XCTAssertFalse(contents.contains("scheduleSmartNotificationsIfNeeded"), "App launch/foreground paths must not trigger local notification scheduling.")
        XCTAssertFalse(contents.contains("NotificationBackgroundTask.shared.triggerImmediately()"), "App lifecycle must not manually trigger notification scheduling while the app is open.")
    }

    func testExplicitAvailabilityRemindersUseCalendarTriggers() throws {
        let serviceFile = repositoryRoot.appendingPathComponent("VibeWatchApp/Core/Services/SmartNotificationService.swift")
        let contents = try String(contentsOf: serviceFile, encoding: .utf8)

        XCTAssertTrue(contents.contains("scheduleAvailabilityReminder"), "SmartNotificationService should expose an explicit user-initiated availability reminder scheduler.")
        XCTAssertTrue(contents.contains("UNCalendarNotificationTrigger"), "Explicit local reminders must use calendar triggers.")
    }

    func testBackgroundDigestQueriesLocalCandidatesAndDeduplicatesBeforeCalendarScheduling() throws {
        let taskFile = repositoryRoot.appendingPathComponent("VibeWatchApp/Core/Services/NotificationBackgroundTask.swift")
        let contents = try String(contentsOf: taskFile, encoding: .utf8)

        XCTAssertTrue(contents.contains("BGAppRefreshTaskRequest(identifier: Self.identifier)"), "Background digest must keep using the existing BGTask identifier.")
        XCTAssertTrue(contents.contains("6 * 60 * 60"), "Background digest should be scheduled roughly every 6 hours.")
        XCTAssertTrue(contents.contains("media_availability"), "Background digest must query local availability candidates from SQLite.")
        XCTAssertTrue(contents.contains("list_items"), "Background digest must query local watchlist items from SQLite.")
        XCTAssertTrue(contents.contains("wasAlreadySent(eventKey: eventKey, channel: .localDigest"), "Background digest must deduplicate through NotificationRepository.wasAlreadySent.")
        XCTAssertTrue(contents.contains("UNCalendarNotificationTrigger"), "Background digest notifications must use calendar triggers.")
        XCTAssertFalse(contents.contains("schedulePersonalizedNotifications"), "Background digest must not use the old implicit personalized scheduler.")
    }

    func testBackgroundDigestHasRequiredBackgroundFetchMode() throws {
        let infoPlist = repositoryRoot.appendingPathComponent("VibeWatchApp/Info.plist")
        let data = try Data(contentsOf: infoPlist)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let modes = try XCTUnwrap(plist["UIBackgroundModes"] as? [String])

        XCTAssertTrue(modes.contains("fetch"), "BGAppRefreshTaskRequest requires UIBackgroundModes to include fetch.")
    }

    func testSwiftUILifecycleSchedulesBackgroundDigestWhenSceneMovesToBackground() throws {
        let appFile = repositoryRoot.appendingPathComponent("VibeWatchApp/App/VibeWatchApp.swift")
        let contents = try String(contentsOf: appFile, encoding: .utf8)

        XCTAssertTrue(contents.contains("@Environment(\\.scenePhase)"), "SwiftUI lifecycle should observe scenePhase because AppDelegate applicationDidEnterBackground is not reliable for every device path.")
        XCTAssertTrue(contents.contains("scenePhase == .background"), "The app should explicitly handle the SwiftUI background scene phase.")
        XCTAssertTrue(contents.contains("NotificationBackgroundTask.shared.scheduleNextRun()"), "The SwiftUI background scene phase should schedule the notification BGTask request.")
    }

    func testSmartNotificationsOwnsTheAppRefreshSchedulingSlot() throws {
        let appDelegateFile = repositoryRoot.appendingPathComponent("VibeWatchApp/App/AppDelegate.swift")
        let appFile = repositoryRoot.appendingPathComponent("VibeWatchApp/App/VibeWatchApp.swift")
        let taskFile = repositoryRoot.appendingPathComponent("VibeWatchApp/Core/Services/NotificationBackgroundTask.swift")
        let appDelegate = try String(contentsOf: appDelegateFile, encoding: .utf8)
        let app = try String(contentsOf: appFile, encoding: .utf8)
        let task = try String(contentsOf: taskFile, encoding: .utf8)

        XCTAssertFalse(appDelegate.contains("DiscoveryCarouselBackgroundRefresher.shared.scheduleNextRefresh()"), "Only one BGAppRefresh request should be scheduled; smart notifications owns that slot.")
        XCTAssertFalse(app.contains("DiscoveryCarouselBackgroundRefresher.shared.scheduleNextRefresh()"), "SwiftUI background handling should not schedule a competing BGAppRefresh request.")
        XCTAssertFalse(task.contains("DiscoveryCarouselBackgroundRefresher.shared.refreshNow()"), "The notification BGTask must stay local/SQLite-only and avoid Discovery network refresh work.")
        XCTAssertFalse(task.contains("generatePersonalizedCarousels"), "The notification BGTask must not trigger remote Discovery generation.")
    }

    func testMainActorBackgroundTaskHandlersRegisterOnMainQueue() throws {
        let taskFiles = [
            "VibeWatchApp/Core/Services/NotificationBackgroundTask.swift",
            "VibeWatchApp/Core/Services/DiscoveryCarouselBackgroundRefresher.swift",
            "VibeWatchApp/Core/Services/CerebrasBackendBackgroundScheduler.swift"
        ]

        for relativePath in taskFiles {
            let file = repositoryRoot.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: file, encoding: .utf8)

            XCTAssertTrue(
                contents.contains("using: DispatchQueue.main"),
                "\(relativePath) is @MainActor, so BGTaskScheduler must invoke its launch handler on the main queue."
            )
        }
    }

    func testNotificationBackgroundTaskUsesUnifiedLoggingForDeviceDiagnostics() throws {
        let taskFile = repositoryRoot.appendingPathComponent("VibeWatchApp/Core/Services/NotificationBackgroundTask.swift")
        let contents = try String(contentsOf: taskFile, encoding: .utf8)

        XCTAssertTrue(contents.contains("import os.log"), "Device BGTask diagnostics should use unified logging, not only print-based debug logs.")
        XCTAssertTrue(contents.contains("OSLog("), "NotificationBackgroundTask should expose a Console.app-visible log category.")
        XCTAssertTrue(contents.contains("os_log(\"Background task started\""), "The BGTask launch handler must emit a unified log before doing work.")
    }

    func testWatchlistProviderLoadingPopulatesRepositoryAvailabilityForBackgroundDigest() throws {
        let listsFile = repositoryRoot.appendingPathComponent("VibeWatchApp/Features/Lists/Views/ListsView.swift")
        let contents = try String(contentsOf: listsFile, encoding: .utf8)

        XCTAssertTrue(contents.contains("private let mediaRepository"), "Watchlist provider loading should use MediaRepository so media_availability is populated for the background digest.")
        XCTAssertTrue(contents.contains("mediaRepository.availability(for:"), "Loading providers from watchlist rows must write/read the repository availability cache used by NotificationBackgroundTask.")
    }
}
