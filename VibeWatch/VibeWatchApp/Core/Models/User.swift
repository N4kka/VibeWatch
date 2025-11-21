import Foundation

struct User: Codable, Identifiable {
    let id: String
    let email: String
    var displayName: String?
    var avatarURL: String?
    var selectedProviders: [String]
    var createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case selectedProviders = "selected_providers"
        case createdAt = "created_at"
    }
}
