import Foundation

actor PostHogClient {
    static let shared = PostHogClient()

    private static let queueKey = "posthog.queue.v1"

    struct Diagnostics {
        let queueCount: Int
        let isFlushing: Bool
        let flushAttemptCount: Int
        let lastFlushErrorDescription: String?
        let lastFlushErrorAt: Date?
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

    private let queueKey = PostHogClient.queueKey
    private var queue: [EventPayload] = []
    private var isFlushing = false
    private var lastFlushError: PostHogError?
    private var lastFlushErrorAt: Date?
    private var flushAttemptCount = 0

    private init() {
        queue = Self.loadQueue()
        Self.logInitializationStatus()
    }

    /// Log PostHog configuration status on startup for production debugging
    private static func logInitializationStatus() {
        let apiKey = Config.posthogApiKey
        let host = Config.posthogHost

        Logger.info("[PostHogClient] Initialized - API Key present: \(!apiKey.isEmpty), Host: \(host.isEmpty ? "MISSING" : host)")

        if apiKey.isEmpty {
            Logger.error("[PostHogClient] POSTHOG_API_KEY is missing! Analytics will not be sent.")
        }

        if host.isEmpty {
            Logger.error("[PostHogClient] POSTHOG_HOST is missing! Analytics will not be sent.")
        }

        if !apiKey.isEmpty && !host.isEmpty {
            Logger.info("[PostHogClient] Configuration valid - ready to capture events")
        }
    }

    func capture(
        event: String,
        distinctId: String,
        userProperties: [String: PostHogValue]? = nil,
        properties: [String: PostHogValue]? = nil,
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
                merged[key] = value
            }
        }

        if let userProperties {
            merged["$set"] = .object(userProperties)
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
                "$anon_distinct_id": .string(anonymousDistinctId)
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
            lastFlushErrorAt: lastFlushErrorAt
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
            Logger.warning("[PostHog] Flush failed: \(error)")
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

    private static func loadQueue() -> [EventPayload] {
        guard let data = UserDefaults.standard.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([EventPayload].self, from: data)) ?? []
    }
}

enum PostHogValue: Codable, Sendable {
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
}
