import XCTest
@testable import VibeWatchApp

final class ClipCommentServiceTests: XCTestCase {

    // MARK: - BUG-01: commentRPCDisabled flag removal

    /// RED test: After BUG-01 fix, commentRPCDisabled must not exist as a property.
    /// Currently FAILS because the property is still declared at ClipCommentService.swift line 17.
    @MainActor
    func testCommentRPCDisabledFlagDoesNotExist() {
        let mirror = Mirror(reflecting: ClipCommentService.shared)
        let hasFlag = mirror.children.contains { $0.label == "commentRPCDisabled" }
        XCTAssertFalse(hasFlag, "commentRPCDisabled property must be removed from ClipCommentService")
    }
}
