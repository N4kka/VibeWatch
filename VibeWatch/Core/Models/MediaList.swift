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

// Extended model for display with cached metadata
struct MediaListItem: Identifiable {
    let id: String
    let listId: String
    let tmdbId: Int
    let type: MediaType
    let position: Int
    let notes: String?
    let watched: Bool
    let addedAt: Date
    
    // Cached metadata from TMDB
    let title: String
    let posterURL: URL?
    let releaseDate: String?
    let rating: Double?
    let runtime: Int?
    let overview: String?
    
    init(from listItem: ListItem, title: String, posterPath: String?, releaseDate: String?, rating: Double?, runtime: Int?, overview: String?) {
        self.id = listItem.id
        self.listId = listItem.listId
        self.tmdbId = listItem.tmdbId
        self.type = listItem.type
        self.position = listItem.position
        self.notes = listItem.notes
        self.watched = listItem.watched
        self.addedAt = listItem.addedAt
        self.title = title
        self.posterURL = posterPath.map { URL(string: "https://image.tmdb.org/t/p/w500\($0)") } ?? nil
        self.releaseDate = releaseDate
        self.rating = rating
        self.runtime = runtime
        self.overview = overview
    }
}

enum MediaType: String, Codable {
    case movie
    case tv
}
