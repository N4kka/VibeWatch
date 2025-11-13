import Foundation

struct MediaList: Codable, Identifiable {
    let id: String
    let userId: String
    let title: String
    let description: String?
    let visibility: ListVisibility
    var items: [ListItem]
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, visibility, items
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum ListVisibility: String, Codable {
    case `private`
    case shared
    case `public`
}

struct ListItem: Codable, Identifiable {
    let id: String
    let listId: String
    let tmdbId: Int
    let type: MediaType
    let position: Int
    let notes: String?
    let watched: Bool
    let addedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, position, notes, watched, type
        case listId = "list_id"
        case tmdbId = "tmdb_id"
        case addedAt = "added_at"
    }
}

enum MediaType: String, Codable {
    case movie
    case tv
}
