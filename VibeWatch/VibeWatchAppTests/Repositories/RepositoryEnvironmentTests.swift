import SwiftUI
import XCTest
@testable import VibeWatchApp

@MainActor
final class RepositoryEnvironmentTests: XCTestCase {
    func testDependencyContainerCreatesLiveRepositories() {
        let container = DependencyContainer.shared

        XCTAssertTrue(container.listRepository is LiveListRepository)
        XCTAssertTrue(container.mediaRepository is LiveMediaRepository)
        XCTAssertTrue(container.discoveryRepository is LiveDiscoveryRepository)
        XCTAssertTrue(container.notificationRepository is LiveNotificationRepository)
    }

    func testRepositoryEnvironmentValuesCanBeOverriddenWithMocks() {
        var values = EnvironmentValues()

        let listRepository = MockListRepository()
        let mediaRepository = MockMediaRepository()
        let discoveryRepository = MockDiscoveryRepository()
        let notificationRepository = MockNotificationRepository()

        values.listRepository = listRepository
        values.mediaRepository = mediaRepository
        values.discoveryRepository = discoveryRepository
        values.notificationRepository = notificationRepository

        XCTAssertTrue(values.listRepository === listRepository)
        XCTAssertTrue(values.mediaRepository === mediaRepository)
        XCTAssertTrue(values.discoveryRepository === discoveryRepository)
        XCTAssertTrue(values.notificationRepository === notificationRepository)
    }
}
