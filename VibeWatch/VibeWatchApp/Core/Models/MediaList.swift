import Foundation

enum MediaType: String, Codable {
    case movie
    case tv
}

enum ListType: String, Codable, CaseIterable {
    case watchlist = "watchlist"
    case seen = "seen"
    case liked = "liked"
    case disliked = "disliked"
    case custom = "custom"
    
    var icon: String {
        switch self {
        case .watchlist: return "bookmark.fill"
        case .seen: return "eye.fill"
        case .liked: return "hand.thumbsup.fill"
        case .disliked: return "hand.thumbsdown.fill"
        case .custom: return "list.bullet"
        }
    }

    var displayName: String {
        switch self {
        case .watchlist: return "Watchlist"
        case .seen: return "Seen"
        case .liked: return "Liked"
        case .disliked: return "Disliked"
        case .custom: return "Custom"
        }
    }

    init?(databaseValue: String) {
        switch databaseValue.lowercased() {
        case "watchlist": self = .watchlist
        case "seen": self = .seen
        case "liked": self = .liked
        case "disliked": self = .disliked
        case "custom": self = .custom
        default: return nil
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
        rawValue.localizedMainSafe()
    }
}

enum FilterOption: String, CaseIterable {
    case all = "filter.all"
    case movies = "filter.movies"
    case tvShows = "filter.tvSeries"

    var displayName: String {
        rawValue.localizedMainSafe()
    }
}

// MARK: - SQLite Dictionary Conversion

extension MediaListItem {
    /// Create a MediaListItem from a SQLite row dictionary
    static func from(dictionary row: [String: Any]) -> MediaListItem? {
        guard let id = row["id"] as? String,
              let mediaId = row["media_id"] as? Int,
              let mediaTypeRaw = row["media_type"] as? String,
              let mediaType = MediaType(rawValue: mediaTypeRaw),
              let title = row["title"] as? String else {
            return nil
        }

        // Parse added_at date
        let addedAt: Date
        if let addedAtString = row["added_at"] as? String {
            addedAt = ISO8601DateFormatter().date(from: addedAtString) ?? Date()
        } else {
            addedAt = Date()
        }

        // Parse origin_country JSON array
        var originCountry: [String]?
        if let originCountryJson = row["origin_country"] as? String,
           let data = originCountryJson.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String].self, from: data) {
            originCountry = parsed
        }

        // Parse genres JSON array
        var genres: [Int]?
        if let genresJson = row["genres"] as? String,
           let data = genresJson.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([Int].self, from: data) {
            genres = parsed
        }

        return MediaListItem(
            id: id,
            mediaId: mediaId,
            mediaType: mediaType,
            title: title,
            posterPath: row["poster_path"] as? String,
            addedAt: addedAt,
            runtime: row["runtime"] as? Int,
            voteAverage: row["vote_average"] as? Double,
            voteCount: row["vote_count"] as? Int,
            originCountry: originCountry,
            releaseDate: row["release_date"] as? String,
            genres: genres,
            overview: row["overview"] as? String
        )
    }
}
