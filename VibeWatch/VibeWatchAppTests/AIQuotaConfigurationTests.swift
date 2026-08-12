import XCTest
@testable import VibeWatchApp

final class AIQuotaConfigurationTests: XCTestCase {
    func testChatbotDailyRequestLimitsMatchProductTiers() {
        XCTAssertEqual(AppConstants.AI.freeDailyRequestLimit, 5)
        XCTAssertEqual(AppConstants.AI.proDailyRequestLimit, 10)
    }
}
