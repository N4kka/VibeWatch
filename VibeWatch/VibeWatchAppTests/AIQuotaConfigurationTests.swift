import XCTest
@testable import VibeWatchApp

final class AIQuotaConfigurationTests: XCTestCase {
    func testChatbotDailyRequestLimitsMatchProductTiers() {
        XCTAssertEqual(AppConstants.AI.freeDailyRequestLimit, 8)
        XCTAssertEqual(AppConstants.AI.proDailyRequestLimit, 20)
    }
}
