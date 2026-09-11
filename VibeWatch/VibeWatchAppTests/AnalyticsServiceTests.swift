import XCTest
@testable import VibeWatchApp

/// Records what would have been sent to PostHog.
final class SpyAnalyticsBackend: AnalyticsBackend {
    struct Captured {
        let event: String
        let properties: [String: Any]?
        let userProperties: [String: Any]?
    }

    var captured: [Captured] = []
    var screens: [String] = []
    var identified: [(distinctId: String, userProperties: [String: Any]?, setOnce: [String: Any]?)] = []
    var resetCount = 0
    var optIns = 0
    var optOuts = 0
    var registered: [[String: Any]] = []
    var exceptions: [(error: Error, properties: [String: Any]?)] = []
    var exceptionSteps: [String] = []
    var recordingActive = false
    var recordingStarts = 0
    var recordingStops = 0
    var flushCount = 0

    func capture(_ event: String, properties: [String: Any]?, userProperties: [String: Any]?) {
        captured.append(Captured(event: event, properties: properties, userProperties: userProperties))
    }

    func screen(_ name: String, properties: [String: Any]?) { screens.append(name) }

    func identify(_ distinctId: String, userProperties: [String: Any]?, userPropertiesSetOnce: [String: Any]?) {
        identified.append((distinctId, userProperties, userPropertiesSetOnce))
    }

    func reset() { resetCount += 1 }
    func optIn() { optIns += 1 }
    func optOut() { optOuts += 1 }
    func register(_ superProperties: [String: Any]) { registered.append(superProperties) }

    func captureException(_ error: Error, properties: [String: Any]?) {
        exceptions.append((error, properties))
    }

    func addExceptionStep(_ message: String, properties: [String: Any]?) {
        exceptionSteps.append(message)
    }

    func startSessionRecording(resumeCurrent: Bool) {
        recordingActive = true
        recordingStarts += 1
    }

    func stopSessionRecording() {
        recordingActive = false
        recordingStops += 1
    }

    func isSessionReplayActive() -> Bool { recordingActive }
    func distinctId() -> String { "spy-distinct-id" }
    func flush() { flushCount += 1 }
}

@MainActor
final class AnalyticsServiceTests: XCTestCase {

    private var spy: SpyAnalyticsBackend!

    override func setUp() {
        super.setUp()
        spy = SpyAnalyticsBackend()
        AnalyticsService.shared._setBackendForTesting(spy, enabled: true)
    }

    override func tearDown() {
        AnalyticsService.shared._setBackendForTesting(nil, enabled: true)
        spy = nil
        super.tearDown()
    }

    // MARK: - Consenso

    /// La falla storica: l'$identify partiva anche con le analytics disattivate.
    func testIdentifyIsBlockedWhenDisabled() {
        AnalyticsService.shared._setBackendForTesting(spy, enabled: false)

        AnalyticsService.shared.setUserId("user-1", signedUpAt: Date())

        XCTAssertTrue(spy.identified.isEmpty, "un utente opted-out non deve produrre $identify")
    }

    func testIdentifyCarriesPersonPropertiesButNoEmail() {
        AnalyticsService.shared.setUserId("user-1", signedUpAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(spy.identified.count, 1)
        XCTAssertEqual(spy.identified.first?.distinctId, "user-1")
        let props = spy.identified.first?.userProperties ?? [:]
        XCTAssertNotNil(props["preferred_language"])
        XCTAssertNil(props["email"], "niente PII: l'email non deve mai arrivare a PostHog")
        XCTAssertEqual(spy.identified.first?.setOnce?["signed_up_at"] as? String,
                       "1970-01-01T00:00:00Z")
    }

    func testDisabledStopsCaptureAndOptsOut() {
        AnalyticsService.shared.setEnabled(false)
        AnalyticsService.shared.track(.appOpen(installId: "i"))

        XCTAssertEqual(spy.optOuts, 1)
        XCTAssertTrue(spy.captured.isEmpty)

        AnalyticsService.shared.setEnabled(true)
        XCTAssertEqual(spy.optIns, 1)
    }

    /// Disattivare le analytics ferma anche una registrazione replay in corso.
    func testDisablingStopsActiveReplay() {
        AnalyticsService.shared.track(.mediaRated(mediaType: "movie", mediaId: 1, rating: 4, previousRating: nil))
        XCTAssertTrue(spy.recordingActive)

        AnalyticsService.shared.setEnabled(false)
        XCTAssertFalse(spy.recordingActive)
    }

    // MARK: - Reset

    func testResetClearsIdentityAndReRegistersSuperProperties() {
        AnalyticsService.shared.setUserId("user-1")
        AnalyticsService.shared.reset()

        XCTAssertEqual(spy.resetCount, 1)
        let last = spy.registered.last ?? [:]
        XCTAssertNotNil(last["install_id"], "reset() deve ri-registrare le super properties")
        XCTAssertEqual(last["schema_version"] as? Int, PostHogAnalyticsBackend.schemaVersion)
    }

    // MARK: - Catalogo eventi (i legacy devono restare identici sul wire)

    func testLegacyEventNamesAreByteIdentical() {
        AnalyticsService.shared.trackAppOpen()
        AnalyticsService.shared.logItemAddedToList(listType: "watchlist", mediaType: "movie")
        AnalyticsService.shared.logPaywallViewed(source: "clips_limit", type: "daily_limit")

        let names = spy.captured.map(\.event)
        XCTAssertTrue(names.contains("app_open"))
        XCTAssertTrue(names.contains("add_to_wishlist"))
        XCTAssertTrue(names.contains("paywall_viewed"))

        let addToList = spy.captured.first { $0.event == "add_to_wishlist" }
        XCTAssertEqual(addToList?.properties?["list_type"] as? String, "watchlist")
        XCTAssertEqual(addToList?.properties?["media_type"] as? String, "movie")

        let paywall = spy.captured.first { $0.event == "paywall_viewed" }
        XCTAssertEqual(paywall?.properties?["source"] as? String, "clips_limit")
        XCTAssertEqual(paywall?.properties?["type"] as? String, "daily_limit")
    }

    func testOnboardingCompletedUsesCanonicalName() {
        AnalyticsService.shared.track(.onboardingCompleted)
        XCTAssertEqual(spy.captured.last?.event, "onboarding_completed",
                       "il nome divergente 'onboarding_complete' non deve riapparire")
    }

    func testContextIsMergedIntoProperties() {
        AnalyticsService.shared.track(
            .feedCardOpened(activityType: "rated", position: 2),
            context: AnalyticsContext(source: "feed", position: 5)
        )
        let props = spy.captured.last?.properties ?? [:]
        XCTAssertEqual(props["activity_type"] as? String, "rated")
        XCTAssertEqual(props["source"] as? String, "feed")
        XCTAssertEqual(props["position"] as? Int, 5, "il context vince sul valore dell'evento")
    }

    // MARK: - Screen

    func testScreenViewEmitsBothLegacyAndNative() {
        AnalyticsService.shared.logScreenView(screenName: "Search")

        XCTAssertEqual(spy.captured.last?.event, "screen_view")
        XCTAssertEqual(spy.captured.last?.properties?["screen_name"] as? String, "Search")
        XCTAssertEqual(spy.screens, ["Search"])
    }

    // MARK: - Replay condizionale

    func testCoreActionStartsReplayOnceWithMarker() {
        AnalyticsService.shared.track(.mediaRated(mediaType: "movie", mediaId: 1, rating: 4, previousRating: nil))
        AnalyticsService.shared.track(.mediaRated(mediaType: "movie", mediaId: 2, rating: 3, previousRating: nil))

        XCTAssertEqual(spy.recordingStarts, 1, "una registrazione già attiva non riparte")
        let markers = spy.captured.filter { $0.event == "replay_started" }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.properties?["trigger"] as? String, "media_rated")
    }

    func testNonCoreEventDoesNotStartReplay() {
        AnalyticsService.shared.track(.screenView(screenName: "Search", screenClass: nil))
        XCTAssertEqual(spy.recordingStarts, 0)
    }

    // MARK: - Coda legacy

    func testLegacyQueueKeysAreGone() {
        // L'init del singleton (già avvenuto) deve aver rimosso le chiavi del client fatto in casa.
        XCTAssertNil(UserDefaults.standard.object(forKey: "posthog.queue.v1"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "posthog.queue.v2"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "analytics.lastIdentifiedUserId"))
    }

    // MARK: - PostHogCrashReporter

    func testCrashReporterRoutesToBackend() {
        let reporter = PostHogCrashReporter(backend: spy)

        reporter.record(AppError.quotaExceeded, userInfo: ["context": "test"])
        XCTAssertEqual(spy.exceptions.count, 1)
        XCTAssertEqual(spy.exceptions.first?.properties?["context"] as? String, "test")

        reporter.log("breadcrumb")
        XCTAssertEqual(spy.exceptionSteps, ["breadcrumb"])

        reporter.setCustomValue("42", forKey: "install_id")
        XCTAssertEqual(spy.registered.last?["install_id"] as? String, "42")
    }
}
