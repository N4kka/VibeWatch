import XCTest
@testable import VibeWatchApp

/// Tests for AppNavigationManager.handle(userInfo:) — BUG-03
///
/// AppNavigationManager.handle(userInfo:) is already fully implemented.
/// These tests verify the existing behavior and establish a regression guard.
///
/// BUG-03's actual gap is the missing call in SmartNotificationService.handleNotificationTap.
/// These unit tests confirm handle(userInfo:) behaves correctly so the GREEN phase
/// can wire the call site with confidence.
@MainActor
final class AppNavigationManagerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // Clear any existing deep link target before each test
        AppNavigationManager.shared.clearDeepLinkTarget()
    }

    override func tearDown() async throws {
        // Restore clean state after each test
        AppNavigationManager.shared.clearDeepLinkTarget()
        try await super.tearDown()
    }

    // MARK: - BUG-03: Valid payload must set deepLinkTarget

    func testHandleUserInfoSetsDeepLinkTargetForMovie() {
        // BUG-03: Valid movie payload must set deepLinkTarget
        let userInfo: [AnyHashable: Any] = [
            "type": "recommendation",
            "media_id": "550",
            "media_type": "movie"
        ]
        AppNavigationManager.shared.handle(userInfo: userInfo)
        XCTAssertNotNil(AppNavigationManager.shared.deepLinkTarget,
            "handle(userInfo:) must set deepLinkTarget for a valid movie payload")
    }

    func testHandleUserInfoSetsDeepLinkTargetForTV() {
        // BUG-03: Valid TV payload must set deepLinkTarget
        let userInfo: [AnyHashable: Any] = [
            "type": "recommendation",
            "media_id": "1399",
            "media_type": "tv"
        ]
        AppNavigationManager.shared.handle(userInfo: userInfo)
        XCTAssertNotNil(AppNavigationManager.shared.deepLinkTarget,
            "handle(userInfo:) must set deepLinkTarget for a valid TV payload")
    }

    func testHandleUserInfoSetsCorrectMediaIdAndType() {
        // BUG-03: deepLinkTarget must carry the exact media_id and media_type from payload
        let userInfo: [AnyHashable: Any] = [
            "media_id": "27205",
            "media_type": "movie"
        ]
        AppNavigationManager.shared.handle(userInfo: userInfo)
        let target = AppNavigationManager.shared.deepLinkTarget
        XCTAssertEqual(target?.mediaId, 27205,
            "deepLinkTarget.mediaId must match the media_id from the payload")
        XCTAssertEqual(target?.mediaType, "movie",
            "deepLinkTarget.mediaType must match the media_type from the payload")
    }

    // MARK: - BUG-03: Missing media_id must leave deepLinkTarget nil

    func testHandleUserInfoWithMissingMediaIdDoesNotSetDeepLinkTarget() {
        // BUG-03: Payload missing media_id must leave deepLinkTarget nil
        let userInfo: [AnyHashable: Any] = [
            "type": "recommendation"
            // media_id intentionally absent
        ]
        AppNavigationManager.shared.handle(userInfo: userInfo)
        XCTAssertNil(AppNavigationManager.shared.deepLinkTarget,
            "handle(userInfo:) must not set deepLinkTarget when media_id is absent")
    }

    func testHandleUserInfoWithInvalidMediaTypeDoesNotSetDeepLinkTarget() {
        // BUG-03: Payload with unrecognised media_type must leave deepLinkTarget nil
        let userInfo: [AnyHashable: Any] = [
            "media_id": "550",
            "media_type": "podcast" // invalid type
        ]
        AppNavigationManager.shared.handle(userInfo: userInfo)
        XCTAssertNil(AppNavigationManager.shared.deepLinkTarget,
            "handle(userInfo:) must not set deepLinkTarget for unsupported media_type values")
    }

    // MARK: - clearDeepLinkTarget

    func testClearDeepLinkTargetNilsTheTarget() {
        // Regression: clearDeepLinkTarget must actually clear the published property
        AppNavigationManager.shared.handle(userInfo: ["media_id": "1", "media_type": "movie"])
        XCTAssertNotNil(AppNavigationManager.shared.deepLinkTarget, "pre-condition: target must be set")
        AppNavigationManager.shared.clearDeepLinkTarget()
        XCTAssertNil(AppNavigationManager.shared.deepLinkTarget,
            "clearDeepLinkTarget() must set deepLinkTarget to nil")
    }
}
