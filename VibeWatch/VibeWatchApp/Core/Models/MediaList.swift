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
    let description: String?
    let type: ListType
    let createdAt: Date
    var items: [MediaListItem]

    init(id: String = UUID().uuidString, name: String, description: String? = nil, type: ListType, createdAt: Date = Date(), items: [MediaListItem] = []) {
        self.id = id
        self.name = name
        self.description = description
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
    
    // Extended metadata for filtering and display
    let runtime: Int?              // Movie runtime in minutes
    let voteAverage: Double?       // TMDb rating (0-10)
    let voteCount: Int?            // Number of votes
    let originCountry: [String]?   // ISO country codes (e.g., ["US", "GB"])
    let releaseDate: String?       // Release/first air date (YYYY-MM-DD)
    let genres: [Int]?             // Genre IDs
    let overview: String?          // Description/synopsis
    
    init(
        id: String = UUID().uuidString,
        mediaId: Int,
        mediaType: MediaType,
        title: String,
        posterPath: String?,
        addedAt: Date = Date(),
        runtime: Int? = nil,
        voteAverage: Double? = nil,
        voteCount: Int? = nil,
        originCountry: [String]? = nil,
        releaseDate: String? = nil,
        genres: [Int]? = nil,
        overview: String? = nil
    ) {
        self.id = id
        self.mediaId = mediaId
        self.mediaType = mediaType
        self.title = title
        self.posterPath = posterPath
        self.addedAt = addedAt
        self.runtime = runtime
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.originCountry = originCountry
        self.releaseDate = releaseDate
        self.genres = genres
        self.overview = overview
    }
}

enum SortOption: String, CaseIterable {
    case dateAdded = "sort.dateAdded"
    case title = "sort.title"
    case releaseDate = "sort.releaseDate"
    case rating = "sort.rating"
    
    var displayName: String {
        rawValue.localized
    }
}

enum FilterOption: String, CaseIterable {
    case all = "filter.all"
    case movies = "filter.movies"
    case tvShows = "filter.tvSeries"
    
    var displayName: String {
        rawValue.localized
    }
}
