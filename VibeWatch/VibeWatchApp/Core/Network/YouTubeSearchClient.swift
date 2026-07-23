import Foundation

/// Single entry point for every YouTube Data API call the app makes, via the `youtube-search`
/// Edge Function.
///
/// `search.list` is the most expensive endpoint the API offers: **100 quota units per call**,
/// against a project default of **10.000 units/day**. That is roughly **100 searches per day for
/// the whole app**, shared across every user — not per device. `videos.list` costs 1 unit.
///
/// Two things follow from that, and this type is where both are handled.
///
/// **The call goes through the server.** Asking YouTube directly meant every device paid 100 units
/// for the same "Dune official trailer" query; the proxy caches the answer, so the second device
/// onwards pays nothing. It also keeps the API key out of the app bundle.
///
/// **An exhausted quota is recognised as such.** The five call sites this replaced each built their
/// URL by hand and none could tell a spent quota from an empty result: some checked only for a
/// non-2xx status and returned `nil`, the others decoded the body directly and threw a decoding
/// error. The clip feature degraded silently while the app kept firing requests that could not
/// succeed. Now the exhaustion is recorded and every subsequent call short-circuits until the reset
/// — which YouTube does at midnight **US/Pacific**, not at local midnight.
///
/// Note the two 429s the proxy can return are *not* the same thing: `quota_exhausted` means the
/// daily budget is gone and nothing will work until the reset, while `rate_limited` is the
/// per-caller hourly cap and clears on its own. Only the first one arms the gate.
actor YouTubeSearchClient {

    static let shared = YouTubeSearchClient()

    enum SearchError: LocalizedError, Equatable {
        /// The daily quota is spent. Retrying before `until` cannot succeed.
        case quotaExhausted(until: Date)
        /// The per-caller hourly cap. Transient: this clears without waiting for the daily reset.
        case rateLimited
        case invalidQuery
        case httpError(status: Int)

        var errorDescription: String? {
            switch self {
            case .quotaExhausted(let until):
                return "YouTube daily quota exhausted, resets at \(until)"
            case .rateLimited:
                return "Too many YouTube searches from this device in the last hour"
            case .invalidQuery:
                return "Query could not be encoded"
            case .httpError(let status):
                return "YouTube proxy returned HTTP \(status)"
            }
        }
    }

    private let session: URLSession
    private let endpoint: String
    private let supabaseKey: String
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    /// Survives relaunches: a quota exhausted at 11:00 is still exhausted after a restart at 11:05.
    private static let exhaustedUntilKey = "YouTubeSearchClient.quotaExhaustedUntil"

    private static func defaultEndpoint() -> String {
        let base = Config.supabaseURL
        guard !base.isEmpty else { return "" }
        let host = base.replacingOccurrences(of: ".supabase.co", with: ".functions.supabase.co")
        return "\(host)/youtube-search"
    }

    init(
        session: URLSession? = nil,
        endpoint: String? = nil,
        supabaseKey: String = Config.supabaseAnonKey,
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
        self.endpoint = endpoint ?? Self.defaultEndpoint()
        self.supabaseKey = supabaseKey
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

    /// Searches YouTube (`search.list`, **100 quota units** on a cache miss), or throws
    /// `.quotaExhausted` without making a request when the daily budget is known to be gone.
    func search(
        query: String,
        relevanceLanguage: String? = nil,
        maxResults: Int = 1
    ) async throws -> [YouTubeSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SearchError.invalidQuery }

        var payload: [String: Any] = [
            "action": "search",
            "query": trimmed,
            "maxResults": max(1, min(maxResults, 50))
        ]
        if let relevanceLanguage { payload["relevanceLanguage"] = relevanceLanguage }

        let data = try await post(payload, describing: "search.list")
        return try JSONDecoder().decode(ItemsEnvelope<YouTubeSearchItem>.self, from: data).items
    }

    /// Fetches video status/contentDetails (`videos.list`, **1 quota unit**). Gated on the same
    /// budget: when it is spent this call cannot succeed either.
    func videoDetails(id: String) async throws -> YouTubeVideoItem? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SearchError.invalidQuery }

        let data = try await post(
            ["action": "videoDetails", "videoId": trimmed], describing: "videos.list"
        )
        return try JSONDecoder().decode(ItemsEnvelope<YouTubeVideoItem>.self, from: data).items.first
    }

    /// The proxy answers `{ "items": [...], "cached": Bool }` for both actions.
    private struct ItemsEnvelope<T: Decodable>: Decodable {
        let items: [T]
    }

    /// Shared transport: the quota gate lives here so no call site can bypass it.
    private func post(_ payload: [String: Any], describing endpointName: String) async throws -> Data {
        if let until = quotaExhaustedUntil {
            throw SearchError.quotaExhausted(until: until)
        }

        guard !endpoint.isEmpty, let url = URL(string: endpoint) else {
            throw SearchError.invalidQuery
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SearchError.httpError(status: -1)
        }

        guard (200...299).contains(http.statusCode) else {
            // Both are 429, and conflating them would be a bug in either direction: arming the
            // daily gate on an hourly cap silences YouTube for the rest of the day, and not arming
            // it on a real exhaustion keeps the app hammering a budget that is gone.
            if http.statusCode == 429 {
                switch proxyError(in: data) {
                case "quota_exhausted":
                    let until = Self.nextQuotaReset(after: now())
                    defaults.set(until, forKey: Self.exhaustedUntilKey)
                    Logger.error(
                        "[YouTube] Daily quota exhausted on \(endpointName) — all YouTube calls "
                        + "disabled until \(until). search.list costs 100 of 10.000 units/day."
                    )
                    throw SearchError.quotaExhausted(until: until)
                default:
                    Logger.warning("[YouTube] Rate limited on \(endpointName); will retry later")
                    throw SearchError.rateLimited
                }
            }
            throw SearchError.httpError(status: http.statusCode)
        }

        return data
    }

    private func proxyError(in body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
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
