import Foundation

enum MediaType: String, Codable {
    case movie
    case tv
}

enum ListType: String, Codable, CaseIterable {
    case watchlist = "Watchlist"
    case seen = "Seen"
    case liked = "Liked"
    case disliked = "Disliked"
    case custom = "Custom"
    
    var icon: String {
        switch self {
        case .watchlist: return "bookmark.fill"
        case .seen: return "eye.fill"
        case .liked: return "hand.thumbsup.fill"
        case .disliked: return "hand.thumbsdown.fill"
        case .custom: return "list.bullet"
        }
    }
}

struct MediaList: Identifiable, Codable {
    let id: String
    let name: String
    let type: ListType
    let createdAt: Date
    var items: [MediaListItem]
    
    init(id: String = UUID().uuidString, name: String, type: ListType, createdAt: Date = Date(), items: [MediaListItem] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.createdAt = createdAt
        self.items = items
    }
}

struct MediaListItem: Identifiable, Codable {
    let id: String
    let mediaId: Int
    let mediaType: MediaType
    let title: String
    let posterPath: String?
    let addedAt: Date
    
    init(id: String = UUID().uuidString, mediaId: Int, mediaType: MediaType, title: String, posterPath: String?, addedAt: Date = Date()) {
        self.id = id
        self.mediaId = mediaId
        self.mediaType = mediaType
        self.title = title
        self.posterPath = posterPath
        self.addedAt = addedAt
    }
}

enum SortOption: String, CaseIterable {
    case dateAdded = "Date Added"
    case title = "Title"
    case releaseDate = "Release Date"
    case rating = "Rating"
}

enum FilterOption: String, CaseIterable {
    case all = "All"
    case movies = "Movies"
    case tvShows = "TV Shows"
}
