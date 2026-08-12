import XCTest
@testable import VibeWatchApp

/// Records what a flush would have put on the wire, and lets a test decide the status code.
private actor RecordingTransport: PostHogTransport {
    private(set) var bodies: [Data] = []
    private var statusCode: Int

    init(statusCode: Int = 200) {
        self.statusCode = statusCode
    }

    func send(_ body: Data, to url: URL) async throws -> (Data, HTTPURLResponse) {
        bodies.append(body)
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (Data("{}".utf8), response)
    }

    func recordedBodies() -> [Data] { bodies }

    /// Number of events across every batch sent, read back out of the JSON we actually posted.
    func sentEventCount() -> Int {
        bodies.reduce(0) { total, body in
            guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let batch = json["batch"] as? [[String: Any]] else { return total }
            return total + batch.count
        }
    }
}

final class PostHogClientTests: XCTestCase {

    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuite = "posthog.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        super.tearDown()
    }

    private func makeClient(
        transport: PostHogTransport,
        apiKey: String = "phc_test",
        host: String = "https://eu.i.posthog.com"
    ) -> PostHogClient {
        PostHogClient(
            configuration: PostHogConfiguration(apiKey: apiKey, host: host),
            transport: transport,
            defaults: defaults,
            queueKey: "posthog.queue.test"
        )
    }

    /// The core P2 regression: a flush must empty the queue, not send the first batch and stop.
    /// The old implementation recursed while `isFlushing` was still true, so the recursive call
    /// returned immediately and every event past the first 20 stayed queued indefinitely.
    func testFlushDrainsTheWholeQueueNotJustTheFirstBatch() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)

        for index in 0..<45 {
            await client.capture(event: "event_\(index)", distinctId: "user")
        }

        try await client.flush()

        let sent = await transport.sentEventCount()
        XCTAssertEqual(sent, 45, "every queued event must reach the transport")

        let diagnostics = await client.diagnostics()
        XCTAssertEqual(diagnostics.queueCount, 0, "a successful flush must leave the queue empty")
    }

    /// Events really are put on the wire, with the event name and properties as plain JSON.
    ///
    /// PostHogValue relied on the synthesized enum Codable, which writes
    /// `"distinct_id": {"string":{"_0":"install-1"}}`. PostHog cannot attribute an event whose
    /// `distinct_id` is an object, so the whole funnel was arriving unusable.
    func testCapturedEventReachesTheTransport() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)

        await client.capture(
            event: "app_open",
            distinctId: "install-1",
            userProperties: ["is_pro": true],
            properties: ["source": "test", "clip_count": 3]
        )
        try await client.flush()

        let bodies = await transport.recordedBodies()
        XCTAssertEqual(bodies.count, 1)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual(json["api_key"] as? String, "phc_test")
        let batch = try XCTUnwrap(json["batch"] as? [[String: Any]])
        XCTAssertEqual(batch.first?["event"] as? String, "app_open")
        let properties = try XCTUnwrap(batch.first?["properties"] as? [String: Any])
        XCTAssertEqual(properties["distinct_id"] as? String, "install-1",
            "distinct_id must be a plain string, not a wrapped enum case")
        XCTAssertEqual(properties["source"] as? String, "test")
        XCTAssertEqual(properties["clip_count"] as? Int, 3)
        XCTAssertEqual(properties["$lib"] as? String, "vibewatch-ios")

        let set = try XCTUnwrap(properties["$set"] as? [String: Any])
        XCTAssertEqual(set["is_pro"] as? Bool, true, "a bool must stay a bool, not become 1")
    }

    /// A build with no credentials drops every event. That was silent; it now shows up in
    /// diagnostics, which is the only way anyone finds out the funnel has no data.
    func testUnconfiguredClientCountsDroppedEvents() async {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport, apiKey: "", host: "")

        await client.capture(event: "app_open", distinctId: "install-1")
        await client.capture(event: "clip_viewed", distinctId: "install-1")

        let diagnostics = await client.diagnostics()
        XCTAssertFalse(diagnostics.isConfigured)
        XCTAssertEqual(diagnostics.droppedUnconfiguredCount, 2)
        XCTAssertEqual(diagnostics.queueCount, 0)

        let sent = await transport.sentEventCount()
        XCTAssertEqual(sent, 0)
    }

    /// A rejected batch keeps its events queued: a 5xx must not lose data.
    func testFailedFlushKeepsEventsQueued() async {
        let transport = RecordingTransport(statusCode: 500)
        let client = makeClient(transport: transport)

        await client.capture(event: "app_open", distinctId: "install-1")

        do {
            try await client.flush()
            XCTFail("a non-2xx response must throw")
        } catch {
            // expected
        }

        let diagnostics = await client.diagnostics()
        XCTAssertEqual(diagnostics.queueCount, 1, "a failed flush must not drop the batch")
        XCTAssertNotNil(diagnostics.lastFlushErrorDescription)
    }

    /// The queue survives a process restart: a new client on the same store picks it up.
    func testQueueIsPersistedAcrossInstances() async throws {
        let firstTransport = RecordingTransport(statusCode: 500)
        let first = makeClient(transport: firstTransport)
        await first.capture(event: "app_open", distinctId: "install-1")
        try? await first.flush()   // fails, leaves the event queued

        let secondTransport = RecordingTransport()
        let second = makeClient(transport: secondTransport)
        try await second.flush()

        let sent = await secondTransport.sentEventCount()
        XCTAssertEqual(sent, 1, "an event queued before a restart must still be sent afterwards")
    }

    /// The wiring test: AnalyticsService.trackAppOpen() must reach the shared client. Asserted on
    /// the flush attempt because the shared client's credentials depend on the local build.
    func testTrackAppOpenReachesTheSharedClient() async {
        UserDefaults.standard.set(true, forKey: "analytics.isEnabled")
        UserDefaults.standard.removeObject(forKey: "analytics.firstOpenTracked")

        let before = await PostHogClient.shared.diagnostics().flushAttemptCount

        await MainActor.run {
            AnalyticsService.shared.trackAppOpen()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let after = await PostHogClient.shared.diagnostics().flushAttemptCount
        XCTAssertGreaterThan(after, before, "trackAppOpen must ask the client to flush")
    }

    /// An unconfigured flush reports the reason instead of pretending to have succeeded.
    func testFlushOnUnconfiguredClientThrowsNotConfigured() async {
        let client = makeClient(transport: RecordingTransport(), apiKey: "", host: "")

        do {
            try await client.flush()
            XCTFail("flush must throw when the build has no credentials")
        } catch PostHogClient.PostHogError.notConfigured {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let diagnostics = await client.diagnostics()
        XCTAssertEqual(diagnostics.lastFlushErrorDescription, "Not configured")
        XCTAssertGreaterThan(diagnostics.flushAttemptCount, 0)
    }
}
