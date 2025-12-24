import Foundation

actor PostHogClient {
    static let shared = PostHogClient()

    struct Diagnostics: Sendable {
        let queueCount: Int
        let isFlushing: Bool
        let lastFlushErrorDescription: String?
        let lastFlushErrorAt: Date?
        let flushAttemptCount: Int
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

    private let queueKey = "posthog.queue.v1"
    private var queue: [EventPayload] = []
    private var isFlushing = false
    private var lastFlushError: PostHogError?
    private var lastFlushErrorAt: Date?
    private var flushAttemptCount = 0

    private init() {
        queue = loadQueue()
    }

    func capture(
        event: String,
        distinctId: String,
        userProperties: [String: Any]? = nil,
        properties: [String: Any]? = nil,
        timestamp: Date = Date()
    ) {
        guard !Config.posthogApiKey.isEmpty, !Config.posthogHost.isEmpty else { return }

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

    func flush() async throws {
        flushAttemptCount += 1

        guard !Config.posthogApiKey.isEmpty, !Config.posthogHost.isEmpty else {
            lastFlushError = .notConfigured
            lastFlushErrorAt = Date()
            throw PostHogError.notConfigured
        }

        guard let url = captureURL(from: Config.posthogHost) else {
            lastFlushError = .invalidHost
            lastFlushErrorAt = Date()
            throw PostHogError.invalidHost
        }

        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        guard !queue.isEmpty else { return }

        let batch = Array(queue.prefix(20))
        let envelope = Envelope(api_key: Config.posthogApiKey, batch: batch)
        let body = try JSONEncoder().encode(envelope)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            lastFlushError = .http(statusCode: statusCode, body: bodyString)
            lastFlushErrorAt = Date()
            throw PostHogError.http(statusCode: statusCode, body: bodyString)
        }

        queue.removeFirst(batch.count)
        persistQueue()

        if !queue.isEmpty {
            try await flush()
        }

        lastFlushError = nil
        lastFlushErrorAt = nil
    }

    func diagnostics() -> Diagnostics {
        Diagnostics(
            queueCount: queue.count,
            isFlushing: isFlushing,
            lastFlushErrorDescription: lastFlushError.map { String(describing: $0) },
            lastFlushErrorAt: lastFlushErrorAt,
            flushAttemptCount: flushAttemptCount
        )
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
        if queue.count > 200 {
            queue.removeFirst(queue.count - 200)
        }
        persistQueue()
    }

    private func flushIfNeeded() async {
        guard queue.count >= 10 else { return }
        do {
            try await flush()
        } catch {
            print("📊 [PostHog] Flush failed: \(error)")
            // Keep queue and retry on next flush opportunity.
        }
    }

    private func persistQueue() {
        do {
            let data = try JSONEncoder().encode(queue)
            UserDefaults.standard.set(data, forKey: queueKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: queueKey)
        }
    }

    private func loadQueue() -> [EventPayload] {
        guard let data = UserDefaults.standard.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([EventPayload].self, from: data)) ?? []
    }
}

enum PostHogValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PostHogValue])
    case array([PostHogValue])
    case null

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

    private enum CodingKeys: String, CodingKey {
        case string
        case number
        case bool
        case object
        case array
        case null
    }

    private enum LegacyValueKey: String, CodingKey {
        case _0
    }

    init(from decoder: Decoder) throws {
        let singleValue = try? decoder.singleValueContainer()

        if let container = singleValue {
            if container.decodeNil() {
                self = .null
                return
            }
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            if let value = try? container.decode([String: PostHogValue].self) {
                self = .object(value)
                return
            }
            if let value = try? container.decode([PostHogValue].self) {
                self = .array(value)
                return
            }
        }

        let keyed = try? decoder.container(keyedBy: CodingKeys.self)
        if let keyed, keyed.contains(.string) {
            if let value = try? keyed.decode(String.self, forKey: .string) {
                self = .string(value)
                return
            }
            if let legacy = try? keyed.nestedContainer(keyedBy: LegacyValueKey.self, forKey: .string),
               let value = try? legacy.decode(String.self, forKey: ._0) {
                self = .string(value)
                return
            }
        }
        if let keyed, keyed.contains(.number) {
            if let value = try? keyed.decode(Double.self, forKey: .number) {
                self = .number(value)
                return
            }
            if let legacy = try? keyed.nestedContainer(keyedBy: LegacyValueKey.self, forKey: .number),
               let value = try? legacy.decode(Double.self, forKey: ._0) {
                self = .number(value)
                return
            }
        }
        if let keyed, keyed.contains(.bool) {
            if let value = try? keyed.decode(Bool.self, forKey: .bool) {
                self = .bool(value)
                return
            }
            if let legacy = try? keyed.nestedContainer(keyedBy: LegacyValueKey.self, forKey: .bool),
               let value = try? legacy.decode(Bool.self, forKey: ._0) {
                self = .bool(value)
                return
            }
        }
        if let keyed, keyed.contains(.object) {
            if let value = try? keyed.decode([String: PostHogValue].self, forKey: .object) {
                self = .object(value)
                return
            }
            if let legacy = try? keyed.nestedContainer(keyedBy: LegacyValueKey.self, forKey: .object),
               let value = try? legacy.decode([String: PostHogValue].self, forKey: ._0) {
                self = .object(value)
                return
            }
        }
        if let keyed, keyed.contains(.array) {
            if let value = try? keyed.decode([PostHogValue].self, forKey: .array) {
                self = .array(value)
                return
            }
            if let legacy = try? keyed.nestedContainer(keyedBy: LegacyValueKey.self, forKey: .array),
               let value = try? legacy.decode([PostHogValue].self, forKey: ._0) {
                self = .array(value)
                return
            }
        }
        if let keyed, keyed.contains(.null) {
            self = .null
            return
        }

        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
