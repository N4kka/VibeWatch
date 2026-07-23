import Foundation

/// Single entry point for YouTube Data API `search.list` calls.
///
/// `search.list` is the most expensive endpoint the API offers: **100 quota units per call**,
/// against a project default of **10.000 units/day**. That is roughly **100 searches per day for
/// the whole app**, shared across every user — not per device.
///
/// The four call sites this replaces each built the same URL by hand, and none of them could tell
/// an exhausted quota from an empty result: two checked only for a non-2xx status and returned
/// `nil`, the other two decoded the body directly and threw a decoding error. So when the project
/// ran out of quota the clip feature degraded silently, and the app kept firing requests that could
/// not possibly succeed for the rest of the day.
///
/// This client detects the `quotaExceeded` reason, records it, and short-circuits every subsequent
/// call until the quota resets — which YouTube does at midnight **US/Pacific**, not at local
/// midnight.
actor YouTubeSearchClient {

    static let shared = YouTubeSearchClient()

    enum SearchError: LocalizedError, Equatable {
        /// The project's daily quota is spent. Retrying before `until` cannot succeed.
        case quotaExhausted(until: Date)
        case invalidQuery
        case httpError(status: Int)

        var errorDescription: String? {
            switch self {
            case .quotaExhausted(let until):
                return "YouTube daily quota exhausted, resets at \(until)"
            case .invalidQuery:
                return "Query could not be encoded"
            case .httpError(let status):
                return "YouTube API returned HTTP \(status)"
            }
        }
    }

    private let session: URLSession
    private let apiKey: String
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    /// Survives relaunches: a quota exhausted at 11:00 is still exhausted after a restart at 11:05.
    private static let exhaustedUntilKey = "YouTubeSearchClient.quotaExhaustedUntil"

    init(
        session: URLSession? = nil,
        apiKey: String = Config.youtubeApiKey,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 10
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
        self.apiKey = apiKey
        self.defaults = defaults
        self.now = now
    }

    /// When the quota is known to be spent, or nil if it is believed available.
    var quotaExhaustedUntil: Date? {
        guard let until = defaults.object(forKey: Self.exhaustedUntilKey) as? Date else { return nil }
        guard until > now() else {
            defaults.removeObject(forKey: Self.exhaustedUntilKey)
            return nil
        }
        return until
    }

    /// Searches YouTube, or throws `.quotaExhausted` without spending a request when the daily
    /// quota is already known to be gone.
    func search(query: String, relevanceLanguage: String? = nil) async throws -> [YouTubeSearchItem] {
        if let until = quotaExhaustedUntil {
            throw SearchError.quotaExhausted(until: until)
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SearchError.invalidQuery
        }

        var urlString = "https://www.googleapis.com/youtube/v3/search"
            + "?part=snippet&q=\(encoded)&type=video&videoDuration=short&maxResults=1&key=\(apiKey)"
        if let relevanceLanguage {
            urlString += "&relevanceLanguage=\(relevanceLanguage)"
        }

        guard let url = URL(string: urlString) else { throw SearchError.invalidQuery }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw SearchError.httpError(status: -1)
        }

        guard (200...299).contains(http.statusCode) else {
            if isQuotaExceeded(status: http.statusCode, body: data) {
                let until = Self.nextQuotaReset(after: now())
                defaults.set(until, forKey: Self.exhaustedUntilKey)
                Logger.error(
                    "[YouTube] Daily quota exhausted — search disabled until \(until). "
                    + "search.list costs 100 units of the project's 10.000/day."
                )
                throw SearchError.quotaExhausted(until: until)
            }
            throw SearchError.httpError(status: http.statusCode)
        }

        return try JSONDecoder().decode(YouTubeSearchResponse.self, from: data).items
    }

    /// YouTube answers `403` with `reason: "quotaExceeded"` (or `dailyLimitExceeded`) in the error
    /// payload. The status alone is not enough: `403` also covers a key restricted to another
    /// bundle id, which retrying tomorrow would not fix.
    private func isQuotaExceeded(status: Int, body: Data) -> Bool {
        guard status == 403, let text = String(data: body, encoding: .utf8) else { return false }
        return text.contains("quotaExceeded") || text.contains("dailyLimitExceeded")
    }

    /// The quota window resets at midnight Pacific Time, not at the device's local midnight.
    static func nextQuotaReset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        guard let midnight = calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return date.addingTimeInterval(24 * 60 * 60)
        }
        return midnight
    }
}
