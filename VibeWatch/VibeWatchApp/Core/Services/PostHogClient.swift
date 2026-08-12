import Foundation

/// Where a flush actually sends its bytes. Injected so the client can be tested without a network.
protocol PostHogTransport: Sendable {
    func send(_ body: Data, to url: URL) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionPostHogTransport: PostHogTransport {
    func send(_ body: Data, to url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PostHogClient.PostHogError.http(statusCode: -1, body: "non-HTTP response")
        }
        return (data, http)
    }
}

/// Project credentials. Empty values mean "not configured": the client then drops events, which is
/// exactly the state this app shipped in, so the drop is counted and logged rather than silent.
struct PostHogConfiguration: Sendable {
    let apiKey: String
    let host: String

    var isConfigured: Bool { !apiKey.isEmpty && !host.isEmpty }

    static var fromBundle: PostHogConfiguration {
        PostHogConfiguration(apiKey: Config.posthogApiKey, host: Config.posthogHost)
    }
}

actor PostHogClient {
    static let shared = PostHogClient()

    struct Diagnostics {
        let queueCount: Int
        let isFlushing: Bool
        let flushAttemptCount: Int
        let lastFlushErrorDescription: String?
        let lastFlushErrorAt: Date?
        /// Events thrown away because the build has no PostHog credentials. Non-zero here means
        /// the funnel has no data at all, which is invisible from anywhere else.
        let droppedUnconfiguredCount: Int
        let isConfigured: Bool
    }

    private struct Envelope: Codable {
        let api_key: String
        let batch: [EventPayload]
    }

    private struct EventPayload: Codable {
        let event: String
        let properties: [String: PostHogValue]
        let timestamp: String?
    }

    enum PostHogError: Error {
        case notConfigured
        case invalidHost
        case http(statusCode: Int, body: String)
    }

    /// PostHog's `/batch/` accepts far more, but a small batch keeps a single failure cheap.
    private static let batchSize = 20
    /// Beyond this the oldest events are discarded to bound UserDefaults growth.
    private static let maxQueuedEvents = 200
    /// Enqueueing this many events triggers an opportunistic flush.
    private static let flushThreshold = 10

    private let configuration: PostHogConfiguration
    private let transport: PostHogTransport
    private let defaults: UserDefaults
    private let queueKey: String

    private var queue: [EventPayload] = []
    private var isFlushing = false
    private var lastFlushError: PostHogError?
    private var lastFlushErrorAt: Date?
    private var flushAttemptCount = 0
    private var droppedUnconfiguredCount = 0
    private var hasLoggedMissingConfiguration = false

    init(
        configuration: PostHogConfiguration = .fromBundle,
        transport: PostHogTransport = URLSessionPostHogTransport(),
        defaults: UserDefaults = .standard,
        // v2: anything persisted under v1 was encoded in the broken `{"string":{"_0":…}}` shape
        // and is not worth replaying. The old blob is discarded on first launch.
        queueKey: String = "posthog.queue.v2"
    ) {
        self.configuration = configuration
        self.transport = transport
        self.defaults = defaults
        self.queueKey = queueKey
        self.queue = Self.loadQueue(from: defaults, key: queueKey)
        defaults.removeObject(forKey: "posthog.queue.v1")

        // Configuration status on startup, for production debugging.
        Logger.info("[PostHogClient] Initialized — API key present: \(!configuration.apiKey.isEmpty), "
                    + "host: \(configuration.host.isEmpty ? "MISSING" : configuration.host), "
                    + "queued: \(queue.count)")

        if !configuration.isConfigured {
            Logger.error("[PostHogClient] POSTHOG_API_KEY/POSTHOG_HOST missing from the build "
                         + "(Secrets.xcconfig → Info.plist). No product analytics will be sent.")
        }
    }

    func capture(
        event: String,
        distinctId: String,
        userProperties: [String: Any]? = nil,
        properties: [String: Any]? = nil,
        timestamp: Date = Date()
    ) {
        guard configuration.isConfigured else {
            droppedUnconfiguredCount += 1
            // Once per process: enough to find in a log, not enough to drown it.
            if !hasLoggedMissingConfiguration {
                hasLoggedMissingConfiguration = true
                Logger.error("[PostHogClient] Dropping event '\(event)': no PostHog credentials in "
                             + "this build. Every event from here on is lost silently.")
            }
            return
        }

        var merged: [String: PostHogValue] = [
            "distinct_id": .string(distinctId),
            "$lib": .string("vibewatch-ios"),
            "$os": .string("iOS"),
            "$os_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "$app_version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
            "$app_build": .string(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
        ]

        if let properties {
            for (key, value) in properties {
                merged[key] = PostHogValue(any: value)
            }
        }

        if let userProperties {
            merged["$set"] = .object(userProperties.mapValues { PostHogValue(any: $0) })
        }

        let isoTimestamp = ISO8601DateFormatter().string(from: timestamp)
        enqueue(EventPayload(event: event, properties: merged, timestamp: isoTimestamp))
        Task { await flushIfNeeded() }
    }

    /// Connects anonymous install identity to a logged-in user ID.
    func identify(newDistinctId: String, anonymousDistinctId: String) {
        capture(
            event: "$identify",
            distinctId: newDistinctId,
            properties: [
                "$anon_distinct_id": anonymousDistinctId
            ]
        )
    }

    func diagnostics() -> Diagnostics {
        var errorDescription: String?
        if let error = lastFlushError {
            switch error {
            case .notConfigured:
                errorDescription = "Not configured"
            case .invalidHost:
                errorDescription = "Invalid host"
            case .http(let statusCode, let body):
                errorDescription = "HTTP \(statusCode): \(body)"
            }
        }
        return Diagnostics(
            queueCount: queue.count,
            isFlushing: isFlushing,
            flushAttemptCount: flushAttemptCount,
            lastFlushErrorDescription: errorDescription,
            lastFlushErrorAt: lastFlushErrorAt,
            droppedUnconfiguredCount: droppedUnconfiguredCount,
            isConfigured: configuration.isConfigured
        )
    }

    /// Sends the whole queue, one batch at a time. It used to send a single batch and then call
    /// itself recursively — with `isFlushing` still true, so the recursive call returned
    /// immediately and everything past the first 20 events stayed queued until it aged out of the
    /// 200-event cap. Anyone generating more than 20 events between two flushes lost the excess.
    func flush() async throws {
        flushAttemptCount += 1

        guard configuration.isConfigured else {
            lastFlushError = .notConfigured
            lastFlushErrorAt = Date()
            throw PostHogError.notConfigured
        }

        guard let url = captureURL(from: configuration.host) else {
            lastFlushError = .invalidHost
            lastFlushErrorAt = Date()
            throw PostHogError.invalidHost
        }

        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !queue.isEmpty {
            let batch = Array(queue.prefix(Self.batchSize))
            let envelope = Envelope(api_key: configuration.apiKey, batch: batch)
            let body = try JSONEncoder().encode(envelope)

            let (data, http) = try await transport.send(body, to: url)
            guard (200...299).contains(http.statusCode) else {
                let bodyString = String(data: data, encoding: .utf8) ?? ""
                lastFlushError = .http(statusCode: http.statusCode, body: bodyString)
                lastFlushErrorAt = Date()
                throw PostHogError.http(statusCode: http.statusCode, body: bodyString)
            }

            queue.removeFirst(batch.count)
            persistQueue()
        }

        lastFlushError = nil
        lastFlushErrorAt = nil
    }

    // MARK: - Private

    private func captureURL(from host: String) -> URL? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: "\(trimmed)/batch/")
    }

    private func enqueue(_ event: EventPayload) {
        queue.append(event)
        if queue.count > Self.maxQueuedEvents {
            let overflow = queue.count - Self.maxQueuedEvents
            queue.removeFirst(overflow)
            Logger.warning("[PostHogClient] Queue over \(Self.maxQueuedEvents); dropped \(overflow) oldest event(s).")
        }
        persistQueue()
    }

    private func flushIfNeeded() async {
        guard queue.count >= Self.flushThreshold else { return }
        do {
            try await flush()
        } catch {
            Logger.warning("[PostHog] Flush failed: \(error)")
            // Keep queue and retry on next flush opportunity.
        }
    }

    private func persistQueue() {
        do {
            let data = try JSONEncoder().encode(queue)
            defaults.set(data, forKey: queueKey)
        } catch {
            defaults.removeObject(forKey: queueKey)
        }
    }

    private static func loadQueue(from defaults: UserDefaults, key: String) -> [EventPayload] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([EventPayload].self, from: data)) ?? []
    }
}

/// A JSON value, encoded as JSON.
///
/// This used to rely on the compiler-synthesized `Codable` for an enum with associated values,
/// which encodes `.string("install-1")` as `{"string":{"_0":"install-1"}}`. Every property of every
/// event went out in that shape — including `distinct_id`, which PostHog needs as a plain string to
/// attribute the event at all. The events were being POSTed and accepted (`/batch/` answers 200
/// almost regardless), then ingested as unusable objects.
enum PostHogValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PostHogValue])
    case array([PostHogValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)          // before Double: a JSON `true` must not become 1
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: PostHogValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([PostHogValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value in a PostHog property"
            )
        }
    }

    init(any: Any) {
        if let value = any as? PostHogValue {
            self = value
            return
        }
        if let value = any as? String {
            self = .string(value)
            return
        }
        if let value = any as? Bool {
            self = .bool(value)
            return
        }
        if let value = any as? Int {
            self = .number(Double(value))
            return
        }
        if let value = any as? Double {
            self = .number(value)
            return
        }
        if let value = any as? Float {
            self = .number(Double(value))
            return
        }
        if let value = any as? NSNumber {
            self = .number(value.doubleValue)
            return
        }
        if let value = any as? [String: Any] {
            self = .object(value.mapValues { PostHogValue(any: $0) })
            return
        }
        if let value = any as? [Any] {
            self = .array(value.map { PostHogValue(any: $0) })
            return
        }
        self = .string(String(describing: any))
    }
}
