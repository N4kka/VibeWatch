import Foundation

struct AnalyticsContext {
    let source: String?
    let position: Int?
    let algorithmVersion: String?
    let sessionId: String?

    init(
        source: String? = nil,
        position: Int? = nil,
        algorithmVersion: String? = nil,
        sessionId: String? = nil
    ) {
        self.source = source
        self.position = position
        self.algorithmVersion = algorithmVersion
        self.sessionId = sessionId
    }

    func properties() -> [String: Any] {
        var props: [String: Any] = [:]
        if let source { props["source"] = source }
        if let position { props["position"] = position }
        if let algorithmVersion { props["algorithm_version"] = algorithmVersion }
        if let sessionId { props["session_id"] = sessionId }
        return props
    }

    static func completionRatio(watched: Double, total: Double) -> Double {
        guard total > 0 else { return 0 }
        let ratio = watched / total
        if ratio < 0 { return 0 }
        if ratio > 1 { return 1 }
        return ratio
    }
}
