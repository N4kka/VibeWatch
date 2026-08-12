import Foundation
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

/// The subset of a crash reporter the app actually uses. Abstracted so nothing outside this file
/// imports Crashlytics, and so tests can assert what gets reported without an SDK in the loop.
protocol CrashReporter: AnyObject {
    func setCollectionEnabled(_ enabled: Bool)
    func setUserIdentifier(_ identifier: String?)
    func setCustomValue(_ value: Any, forKey key: String)
    func record(_ error: Error, userInfo: [String: Any])
    func log(_ message: String)
}

/// P3 of SPEC v3: the app had no crash reporting at all. An import that crashes on 3% of devices
/// is invisible without it, and this release ships one to users arriving from a dead product.
///
/// Firebase is already configured for Analytics and Messaging, so Crashlytics costs one SPM
/// product and no new SDK. Collection follows the same opt-out as analytics.
enum CrashReportingService {

    /// Replaced in tests. Defaults to Crashlytics when the SDK is linked, and to a no-op otherwise
    /// so the app keeps building without it.
    static var reporter: CrashReporter = {
        #if canImport(FirebaseCrashlytics)
        return CrashlyticsReporter()
        #else
        return NoopCrashReporter()
        #endif
    }()

    /// Call once, after FirebaseApp.configure().
    static func start(isEnabled: Bool, installId: String) {
        reporter.setCollectionEnabled(isEnabled)
        reporter.setCustomValue(installId, forKey: "install_id")
        Logger.info("[CrashReporting] Started (collection enabled: \(isEnabled))")
    }

    /// Follows the analytics opt-out: a user who turned analytics off gets no crash uploads either.
    static func setCollectionEnabled(_ enabled: Bool) {
        reporter.setCollectionEnabled(enabled)
    }

    /// Ties a crash to an account. nil on sign-out.
    static func setUserId(_ userId: String?) {
        reporter.setUserIdentifier(userId)
    }

    /// A handled error worth seeing in aggregate — recorded as a non-fatal, not a crash.
    static func record(_ error: Error, context: String) {
        reporter.record(error, userInfo: ["context": context])
    }

    /// A breadcrumb attached to whatever crash comes next.
    static func log(_ message: String) {
        reporter.log(message)
    }
}

#if canImport(FirebaseCrashlytics)
private final class CrashlyticsReporter: CrashReporter {
    private var crashlytics: Crashlytics { Crashlytics.crashlytics() }

    func setCollectionEnabled(_ enabled: Bool) {
        crashlytics.setCrashlyticsCollectionEnabled(enabled)
    }

    func setUserIdentifier(_ identifier: String?) {
        crashlytics.setUserID(identifier ?? "")
    }

    func setCustomValue(_ value: Any, forKey key: String) {
        crashlytics.setCustomValue(value, forKey: key)
    }

    func record(_ error: Error, userInfo: [String: Any]) {
        crashlytics.record(error: error, userInfo: userInfo)
    }

    func log(_ message: String) {
        crashlytics.log(message)
    }
}
#endif

final class NoopCrashReporter: CrashReporter {
    func setCollectionEnabled(_ enabled: Bool) {}
    func setUserIdentifier(_ identifier: String?) {}
    func setCustomValue(_ value: Any, forKey key: String) {}
    func record(_ error: Error, userInfo: [String: Any]) {}
    func log(_ message: String) {}
}
