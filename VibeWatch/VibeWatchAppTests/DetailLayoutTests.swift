import CoreGraphics
import XCTest
@testable import VibeWatchApp

final class DetailLayoutTests: XCTestCase {
    func testDetailContentHorizontalInsetMatchesTVShowDetailLayout() {
        XCTAssertEqual(DetailLayout.contentHorizontalInset, CGFloat(50))
    }

    func testSeasonDetailContentUsesFullWidthOuterLayout() {
        XCTAssertEqual(DetailLayout.seasonContentHorizontalInset, CGFloat(0))
    }
}
