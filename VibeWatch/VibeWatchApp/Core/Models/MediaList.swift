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
    /// Visibilità pubblica (solo liste custom). Mirror locale dello stato server (Liste Pubbliche, Fase 1).
    var isPublic: Bool
    /// La lista custom da cui questa è stata copiata ("Crea lista pubblica da questa").
    var sourceListId: String?
    /// Se la sorgente era una lista core (watchlist/seen/liked/disliked), il suo tipo: le core
    /// hanno un id diverso su ogni installazione, il tipo no.
    var sourceListType: ListType?

    var displayName: String {
        switch type {
        case .watchlist: return "lists.watchlist".localized
        case .seen: return "lists.seen".localized
        case .liked: return "lists.liked".localized
        case .disliked: return "lists.disliked".localized
        case .custom: return name
        }
    }

    init(id: String = UUID().uuidString, name: String, description: String? = nil, type: ListType, createdAt: Date = Date(), items: [MediaListItem] = [], isPublic: Bool = false, sourceListId: String? = nil, sourceListType: ListType? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.createdAt = createdAt
        self.items = items
        self.isPublic = isPublic
        self.sourceListId = sourceListId
        self.sourceListType = sourceListType
    }

    // Decodifica tollerante: `isPublic` è opzionale nel JSON storico (es. vecchia migrazione
    // da UserDefaults) → assente ⇒ false, senza rompere la decodifica delle liste esistenti.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.type = try c.decode(ListType.self, forKey: .type)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.items = try c.decodeIfPresent([MediaListItem].self, forKey: .items) ?? []
        self.isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
        self.sourceListId = try c.decodeIfPresent(String.self, forKey: .sourceListId)
        self.sourceListType = try c.decodeIfPresent(ListType.self, forKey: .sourceListType)
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

struct MediaListItemSubtitleComponent: Equatable {
    let text: String
    let showsRatingStar: Bool
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
    func displayOverview(fallback: String?) -> String? {
        if let overview = normalizedOverview(overview) {
            return overview
        }

        return normalizedOverview(fallback)
    }

    func subtitle(seasonCount: Int? = nil, duration: Int? = nil) -> String? {
        let parts = subtitleComponents(seasonCount: seasonCount, duration: duration).map(\.text)
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    func subtitleComponents(seasonCount: Int? = nil, duration: Int? = nil) -> [MediaListItemSubtitleComponent] {
        let resolvedDuration = duration ?? runtime
        var parts: [MediaListItemSubtitleComponent] = []

        if mediaType == .tv, let seasonCount, seasonCount > 0 {
            parts.append(MediaListItemSubtitleComponent(
                text: "\(seasonCount) \(seasonCount == 1 ? "season" : "seasons")",
                showsRatingStar: false
            ))
        }

        if let releaseDate, releaseDate.count >= 4 {
            parts.append(MediaListItemSubtitleComponent(
                text: String(releaseDate.prefix(4)),
                showsRatingStar: false
            ))
        }

        if let voteAverage, voteAverage > 0 {
            parts.append(MediaListItemSubtitleComponent(
                text: String(format: "%.1f", voteAverage),
                showsRatingStar: true
            ))
        }

        if let resolvedDuration, resolvedDuration > 0 {
            parts.append(MediaListItemSubtitleComponent(
                text: Self.formatDuration(resolvedDuration),
                showsRatingStar: false
            ))
        }

        return parts
    }

    func asMovie() -> Movie {
        Movie(
            id: mediaId,
            title: title,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: nil,
            releaseDate: releaseDate,
            voteAverage: voteAverage ?? 0.0,
            voteCount: voteCount ?? 0,
            genreIds: genres,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: 0.0,
            runtime: runtime,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }

    private func normalizedOverview(_ overview: String?) -> String? {
        guard let overview else { return nil }
        let trimmed = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60

        if hours > 0 {
            return "\(hours)h \(remainder)m"
        }

        return "\(minutes)m"
    }

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
