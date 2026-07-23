import XCTest
@testable import VibeWatchApp

/// Covers the quota gate and the proxy contract (audit DEP-004).
///
/// `search.list` costs 100 of the project's 10.000 daily quota units, so the app can afford roughly
/// 100 searches per day across all users. The five call sites this client replaced could not tell
/// an exhausted quota from an empty result — some returned `nil` on any non-2xx, others decoded the
/// error body and threw a decoding error — so the app kept firing requests that could not succeed.
///
/// Calls now go through the `youtube-search` Edge Function, which caches answers so one request
/// serves every user, and which returns **two different 429s**: `quota_exhausted` (the daily budget
/// is gone) and `rate_limited` (the per-caller hourly cap). Conflating them is a bug either way.
final class YouTubeSearchClientTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "YouTubeSearchClientTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(now: @escaping @Sendable () -> Date = { Date() }) -> YouTubeSearchClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return YouTubeSearchClient(
            session: URLSession(configuration: config),
            endpoint: "https://example.functions.supabase.co/youtube-search",
            supabaseKey: "test-publishable-key",
            defaults: defaults,
            now: now
        )
    }

    private static let quotaBody = #"{"error":"quota_exhausted","scope":"global"}"#
    private static let rateLimitBody = #"{"error":"rate_limited","scope":"caller"}"#

    private static let searchBody = """
    {"items":[{"id":{"videoId":"abc123"},"snippet":{"title":"Trailer",
    "thumbnails":{"high":{"url":"https://img.youtube.com/vi/abc123/hq.jpg"}}}}],"cached":true}
    """

    // MARK: - Happy path

    func testSearchDecodesTheProxyEnvelope() async throws {
        StubURLProtocol.stub(status: 200, body: Self.searchBody)
        let items = try await makeClient().search(query: "Dune official trailer")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id.videoId, "abc123")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    /// The proxy is a POST API with the publishable key attached; a GET to googleapis would 404.
    func testRequestIsAPostCarryingTheSupabaseKey() async throws {
        StubURLProtocol.stub(status: 200, body: Self.searchBody)
        _ = try await makeClient().search(query: "Dune", relevanceLanguage: "it", maxResults: 5)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-publishable-key")
        XCTAssertEqual(request.url?.host, "example.functions.supabase.co")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "search")
        XCTAssertEqual(json["query"] as? String, "Dune")
        XCTAssertEqual(json["relevanceLanguage"] as? String, "it")
        XCTAssertEqual(json["maxResults"] as? Int, 5)
    }

    func testVideoDetailsUsesTheVideoDetailsAction() async throws {
        StubURLProtocol.stub(status: 200, body: """
        {"items":[{"status":{"embeddable":true,"uploadStatus":"processed","privacyStatus":"public"},
        "contentDetails":{"contentRating":{}}}],"cached":false}
        """)

        let video = try await makeClient().videoDetails(id: "abc123")
        XCTAssertNotNil(video)

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastBody)) as? [String: Any]
        )
        XCTAssertEqual(json["action"] as? String, "videoDetails")
        XCTAssertEqual(json["videoId"] as? String, "abc123")
    }

    // MARK: - The two 429s

    func testQuotaExhaustedIsRecognisedAndRecorded() async throws {
        StubURLProtocol.stub(status: 429, body: Self.quotaBody)
        let client = makeClient()

        do {
            _ = try await client.search(query: "Dune official trailer")
            XCTFail("an exhausted quota must throw, not return an empty result")
        } catch let error as YouTubeSearchClient.SearchError {
            guard case .quotaExhausted = error else {
                return XCTFail("expected .quotaExhausted, got \(error)")
            }
        }

        let until = await client.quotaExhaustedUntil
        XCTAssertNotNil(until, "the exhaustion has to be recorded, or the next call spends a request")
    }

    /// The point of the gate: once the daily budget is gone, stop calling.
    func testNoFurtherRequestIsSentWhileQuotaIsExhausted() async throws {
        StubURLProtocol.stub(status: 429, body: Self.quotaBody)
        let client = makeClient()

        _ = try? await client.search(query: "first")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        for _ in 0..<5 {
            _ = try? await client.search(query: "again")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1,
            "calls made while the quota is known to be spent must not reach the network")
    }

    /// The per-caller hourly cap clears on its own. Arming the daily gate on it would silence
    /// YouTube for the rest of the day over a transient limit.
    func testRateLimitDoesNotArmTheDailyGate() async throws {
        StubURLProtocol.stub(status: 429, body: Self.rateLimitBody)
        let client = makeClient()

        do {
            _ = try await client.search(query: "Dune")
            XCTFail("expected a throw")
        } catch let error as YouTubeSearchClient.SearchError {
            XCTAssertEqual(error, .rateLimited)
        }

        let until = await client.quotaExhaustedUntil
        XCTAssertNil(until, "an hourly cap must not disable YouTube until the daily reset")

        // And the next call must still be attempted.
        StubURLProtocol.stub(status: 200, body: Self.searchBody)
        let items = try await client.search(query: "Dune")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testOtherHttpErrorsDoNotArmTheDailyGate() async throws {
        StubURLProtocol.stub(status: 502, body: #"{"error":"upstream_error","status":403}"#)
        let client = makeClient()

        do {
            _ = try await client.search(query: "Dune")
            XCTFail("expected a throw")
        } catch let error as YouTubeSearchClient.SearchError {
            XCTAssertEqual(error, .httpError(status: 502))
        }

        let until = await client.quotaExhaustedUntil
        XCTAssertNil(until, "a proxy/upstream failure is not an exhausted quota")
    }

    /// The gate has to lift by itself, otherwise one exhausted day disables the feature forever.
    func testQuotaGateExpiresAfterTheResetTime() async throws {
        StubURLProtocol.stub(status: 429, body: Self.quotaBody)

        let start = Date()
        let exhausted = makeClient(now: { start })
        _ = try? await exhausted.search(query: "first")
        let until = await exhausted.quotaExhaustedUntil
        XCTAssertNotNil(until)

        // A client reading the same store after the reset must see an available quota.
        let afterReset = makeClient(now: { start.addingTimeInterval(48 * 60 * 60) })
        let stillBlocked = await afterReset.quotaExhaustedUntil
        XCTAssertNil(stillBlocked, "the gate must lift once the quota window has rolled over")

        StubURLProtocol.reset()
        StubURLProtocol.stub(status: 200, body: Self.searchBody)
        let items = try await afterReset.search(query: "after reset")
        XCTAssertEqual(items.count, 1)
    }

    /// YouTube resets the window at midnight US/Pacific, not at the device's local midnight.
    func testResetIsComputedInPacificTime() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let noon = pacific.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 12))!
        let reset = YouTubeSearchClient.nextQuotaReset(after: noon)

        let parts = pacific.dateComponents([.year, .month, .day, .hour], from: reset)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.day, 24)
        XCTAssertGreaterThan(reset, noon)
    }
}

// MARK: - Stub transport

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = ""
    nonisolated(unsafe) private(set) static var requestCount = 0
    nonisolated(unsafe) private(set) static var lastRequest: URLRequest?
    nonisolated(unsafe) private(set) static var lastBody: Data?
    private static let lock = NSLock()

    static func stub(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.body = body
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requestCount = 0
        status = 200
        body = ""
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        Self.lastRequest = request
        // URLProtocol strips httpBody into a stream; read it back so assertions can see it.
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let status = Self.status
        let body = Self.body
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
