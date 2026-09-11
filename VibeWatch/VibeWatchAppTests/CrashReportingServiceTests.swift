import XCTest
@testable import VibeWatchApp

/// Records what would have been sent to the error tracker (PostHog since the analytics refactor).
private final class SpyCrashReporter: CrashReporter {
    var collectionEnabled: Bool?
    var userIdentifier: String??
    var customValues: [String: Any] = [:]
    var recorded: [(error: Error, userInfo: [String: Any])] = []
    var logs: [String] = []

    func setCollectionEnabled(_ enabled: Bool) { collectionEnabled = enabled }
    func setUserIdentifier(_ identifier: String?) { userIdentifier = identifier }
    func setCustomValue(_ value: Any, forKey key: String) { customValues[key] = value }
    func record(_ error: Error, userInfo: [String: Any]) { recorded.append((error, userInfo)) }
    func log(_ message: String) { logs.append(message) }
}

/// These tests cover the wiring — that the rest of the app reaches the reporter — not the SDK
/// itself, which is PostHog's problem.
@MainActor
final class CrashReportingServiceTests: XCTestCase {

    private var spy: SpyCrashReporter!
    private var originalReporter: CrashReporter!

    override func setUp() {
        super.setUp()
        originalReporter = CrashReportingService.reporter
        spy = SpyCrashReporter()
        CrashReportingService.reporter = spy
    }

    override func tearDown() {
        CrashReportingService.reporter = originalReporter
        AnalyticsService.shared.setEnabled(true)
        spy = nil
        super.tearDown()
    }

    func testStartEnablesCollectionAndTagsTheInstall() {
        CrashReportingService.start(isEnabled: true, installId: "install-42")

        XCTAssertEqual(spy.collectionEnabled, true)
        XCTAssertEqual(spy.customValues["install_id"] as? String, "install-42")
    }

    /// A handled error still needs a rate: an import that fails on 3% of devices is invisible
    /// otherwise, since it never crashes. ErrorHandler is the funnel now.
    func testHandledErrorIsRecordedAsNonFatal() {
        ErrorHandler.shared.logOnly(AppError.quotaExceeded, context: "clip_playback")

        XCTAssertEqual(spy.recorded.count, 1)
        XCTAssertEqual(spy.recorded.first?.userInfo["context"] as? String, "clip_playback")
    }

    /// Opting out of analytics opts out of crash uploads too.
    func testCollectionFollowsTheAnalyticsOptOut() {
        AnalyticsService.shared.setEnabled(false)
        XCTAssertEqual(spy.collectionEnabled, false)

        AnalyticsService.shared.setEnabled(true)
        XCTAssertEqual(spy.collectionEnabled, true)
    }
}
