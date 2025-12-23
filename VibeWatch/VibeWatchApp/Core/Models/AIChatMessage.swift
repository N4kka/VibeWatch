import Foundation

enum AIChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct AIChatMessage: Codable, Sendable {
    let role: AIChatRole
    let content: String
    let timestamp: Date

    init(role: AIChatRole, content: String, timestamp: Date = Date()) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

