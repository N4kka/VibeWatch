import XCTest
@testable import VibeWatchApp

/// Covers the quota gate added for DEP-004.
///
/// `search.list` costs 100 of the project's 10.000 daily quota units, so the app can afford roughly
/// 100 searches per day across all users. The four call sites this client replaced could not tell
/// an exhausted quota from an empty result — two returned `nil` on any non-2xx, two decoded the
/// error body and threw a decoding error — so the app kept firing requests that could not succeed.
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
            apiKey: "test-key",
            defaults: defaults,
            now: now
        )
    }

    private static let quotaBody = """
    {"error":{"code":403,"errors":[{"reason":"quotaExceeded","domain":"youtube.quota"}]}}
    """

    private static let okBody = """
    {"items":[{"id":{"videoId":"abc123"},"snippet":{"title":"Trailer",
    "thumbnails":{"high":{"url":"https://img.youtube.com/vi/abc123/hq.jpg"}}}}]}
    """

    // MARK: - Happy path

    func testSearchReturnsItems() async throws {
        StubURLProtocol.stub(status: 200, body: Self.okBody)
        let items = try await makeClient().search(query: "Dune official trailer")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id.videoId, "abc123")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    // MARK: - Quota detection

    func testQuotaExceededIsRecognisedAndRecorded() async throws {
        StubURLProtocol.stub(status: 403, body: Self.quotaBody)
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

    /// The point of the gate: once the quota is gone, stop calling.
    func testNoFurtherRequestIsSentWhileQuotaIsExhausted() async throws {
        StubURLProtocol.stub(status: 403, body: Self.quotaBody)
        let client = makeClient()

        _ = try? await client.search(query: "first")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        for _ in 0..<5 {
            _ = try? await client.search(query: "again")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1,
            "calls made while the quota is known to be spent must not reach the network")
    }

    /// A 403 also covers a key restricted to another bundle id — retrying tomorrow would not fix
    /// that, so it must not be recorded as a quota exhaustion.
    func testForbiddenForOtherReasonsIsNotTreatedAsQuota() async throws {
        StubURLProtocol.stub(status: 403, body: """
        {"error":{"code":403,"errors":[{"reason":"ipRefererBlocked"}]}}
        """)
        let client = makeClient()

        do {
            _ = try await client.search(query: "Dune")
            XCTFail("expected a throw")
        } catch let error as YouTubeSearchClient.SearchError {
            guard case .httpError(403) = error else {
                return XCTFail("expected .httpError(403), got \(error)")
            }
        }

        let until = await client.quotaExhaustedUntil
        XCTAssertNil(until, "a non-quota 403 must not disable search for the rest of the day")
    }

    /// The gate has to lift by itself, otherwise one exhausted day disables the feature forever.
    func testQuotaGateExpiresAfterTheResetTime() async throws {
        StubURLProtocol.stub(status: 403, body: Self.quotaBody)

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
        StubURLProtocol.stub(status: 200, body: Self.okBody)
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
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
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
