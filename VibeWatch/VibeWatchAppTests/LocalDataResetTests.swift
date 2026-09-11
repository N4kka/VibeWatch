import XCTest
@testable import VibeWatchApp

/// Il logout puliva il database ma non UserDefaults: cronologia, episodi visti e like alle clip
/// passavano da un account all'altro sullo stesso device. Qui si fissa il confine — cosa se ne va
/// e cosa resta, perché è del device e non di chi ci ha fatto login.
@MainActor
final class LocalDataResetTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sut: LocalDataResetService!

    override func setUp() {
        super.setUp()
        suiteName = "com.vibewatch.tests.localDataReset"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        sut = LocalDataResetService(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        sut = nil
        super.tearDown()
    }

    func testClearRemovesAccountData() {
        defaults.set(Data([1, 2, 3]), forKey: "latestVisitedItems")
        defaults.set(["101_1_1"], forKey: "vibewatch.seen_episodes")
        defaults.set([42], forKey: "vibewatch.seen_shows")
        defaults.set(["clip-1"], forKey: "likedClips")
        defaults.set("session-abc", forKey: "ai_chat_session_id")
        defaults.set(Date(), forKey: "SyncEngine.lastSyncTimestamp")

        sut.clearUserScopedDefaults()

        XCTAssertNil(defaults.object(forKey: "latestVisitedItems"))
        XCTAssertNil(defaults.object(forKey: "vibewatch.seen_episodes"))
        XCTAssertNil(defaults.object(forKey: "vibewatch.seen_shows"))
        XCTAssertNil(defaults.object(forKey: "likedClips"))
        XCTAssertNil(defaults.object(forKey: "ai_chat_session_id"))
        XCTAssertNil(defaults.object(forKey: "SyncEngine.lastSyncTimestamp"))
    }

    /// Le chiavi costruite con l'id dell'utente o della sfida non si possono elencare: se restano,
    /// il nuovo account eredita lo stato "giornata già caricata" del precedente.
    func testClearRemovesKeysBuiltAtRuntime() {
        defaults.set("2026-08-13", forKey: "discovery_last_loaded_day_abc-123")
        defaults.set(true, forKey: "gamification.challenge.watch-3-clips")

        sut.clearUserScopedDefaults()

        XCTAssertNil(defaults.object(forKey: "discovery_last_loaded_day_abc-123"))
        XCTAssertNil(defaults.object(forKey: "gamification.challenge.watch-3-clips"))
    }

    /// L'identità del device, la lingua, il paese e i consensi non appartengono all'account:
    /// cancellarli farebbe ripartire l'app come appena installata a ogni cambio utente — e con un
    /// `deviceIdentifier` nuovo le righe locali resterebbero orfane.
    func testClearKeepsDeviceSettings() {
        defaults.set("device-uuid", forKey: "deviceIdentifier")
        defaults.set("it", forKey: "selectedLanguageCode")
        defaults.set("IT", forKey: "selectedCountryCode")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(true, forKey: "hasLaunchedBefore")
        defaults.set(false, forKey: "analytics.isEnabled")
        defaults.set("authorized", forKey: "trackingPermission.status")

        sut.clearUserScopedDefaults()

        XCTAssertEqual(defaults.string(forKey: "deviceIdentifier"), "device-uuid")
        XCTAssertEqual(defaults.string(forKey: "selectedLanguageCode"), "it")
        XCTAssertEqual(defaults.string(forKey: "selectedCountryCode"), "IT")
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"))
        XCTAssertTrue(defaults.bool(forKey: "hasLaunchedBefore"))
        XCTAssertFalse(defaults.bool(forKey: "analytics.isEnabled"))
        XCTAssertEqual(defaults.string(forKey: "trackingPermission.status"), "authorized")
    }

    /// Gli store degli SDK di terze parti vivono negli stessi UserDefaults: un wipe per esclusione
    /// avrebbe portato via anche lo stato non ancora sincronizzato (es. l'identità RevenueCat o
    /// lo storage dell'SDK PostHog).
    func testClearKeepsThirdPartyState() {
        defaults.set("anon-id", forKey: "com.posthog.sdk.anonymousId")
        defaults.set("rc-user", forKey: "com.revenuecat.userdefaults.appUserID")

        sut.clearUserScopedDefaults()

        XCTAssertNotNil(defaults.object(forKey: "com.posthog.sdk.anonymousId"))
        XCTAssertNotNil(defaults.object(forKey: "com.revenuecat.userdefaults.appUserID"))
    }
}
