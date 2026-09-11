import Foundation

/// The subset of a crash reporter the app actually uses. Abstracted so nothing outside the
/// analytics layer imports the SDK, and so tests can assert what gets reported without an SDK
/// in the loop.
protocol CrashReporter: AnyObject {
    func setCollectionEnabled(_ enabled: Bool)
    func setUserIdentifier(_ identifier: String?)
    func setCustomValue(_ value: Any, forKey key: String)
    func record(_ error: Error, userInfo: [String: Any])
    func log(_ message: String)
}

/// Crash and handled-error reporting, on PostHog error tracking since the analytics refactor:
/// fatal crashes come from the SDK's autocapture (PLCrashReporter), handled errors become
/// `$exception` events, and both correlate with product events and session replay.
///
/// The reporter starts as a no-op and is swapped to `PostHogCrashReporter` by
/// `AnalyticsService.bootstrap()`; tests replace it with a spy.
enum CrashReportingService {

    static var reporter: CrashReporter = NoopCrashReporter()

    /// Call once at launch, after `AnalyticsService.bootstrap()`.
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

    /// A breadcrumb attached to whatever exception comes next.
    static func log(_ message: String) {
        reporter.log(message)
    }
}

final class NoopCrashReporter: CrashReporter {
    func setCollectionEnabled(_ enabled: Bool) {}
    func setUserIdentifier(_ identifier: String?) {}
    func setCustomValue(_ value: Any, forKey key: String) {}
    func record(_ error: Error, userInfo: [String: Any]) {}
    func log(_ message: String) {}
}
