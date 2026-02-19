import XCTest
@testable import VibeWatchApp

final class PostHogClientTests: XCTestCase {
    func testFlushRecordsDiagnosticsOnError() async {
        let client = PostHogClient.shared

        var didThrow = false
        do {
            try await client.flush()
        } catch {
            didThrow = true
        }

        let flushAttempts = PostHogClientTestIntrospection.flushAttemptCount(from: client)
        XCTAssertGreaterThan(flushAttempts, 0)

        let errorDescription = PostHogClientTestIntrospection.lastFlushErrorDescription(from: client)
        if didThrow {
            XCTAssertNotNil(errorDescription)
        }
    }

    func testTrackAppOpenTriggersFlushAttempt() async {
        UserDefaults.standard.set(true, forKey: "analytics.isEnabled")
        UserDefaults.standard.removeObject(forKey: "analytics.firstOpenTracked")

        await MainActor.run {
            AnalyticsService.shared.trackAppOpen()
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        let flushAttempts = PostHogClientTestIntrospection.flushAttemptCount(from: PostHogClient.shared)
        XCTAssertGreaterThan(flushAttempts, 0)
    }
}

private enum PostHogClientTestIntrospection {
    static func lastFlushErrorDescription(from client: PostHogClient) -> String? {
        let mirror = Mirror(reflecting: client)
        for child in mirror.children {
            if child.label == "lastFlushError" {
                return String(describing: child.value)
            }
        }
        return nil
    }

    static func flushAttemptCount(from client: PostHogClient) -> Int {
        let mirror = Mirror(reflecting: client)
        for child in mirror.children {
            if child.label == "flushAttemptCount", let value = child.value as? Int {
                return value
            }
        }
        return 0
    }
}
