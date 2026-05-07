import Foundation

// MARK: - TMDB API Response Models

struct TMDBMovieListResponse: Codable {
    let page: Int
    let results: [TMDBMovie]
    let totalPages: Int
    let totalResults: Int

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }
}

struct TMDBMovie: Codable {
    let id: Int
    let title: String
    let originalTitle: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double
    let voteCount: Int
    let popularity: Double
    let genreIds: [Int]
    let adult: Bool
    let originalLanguage: String

    enum CodingKeys: String, CodingKey {
        case id, title, overview, popularity, adult
        case originalTitle = "original_title"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case genreIds = "genre_ids"
        case originalLanguage = "original_language"
    }
}

struct TMDBTVListResponse: Codable {
    let page: Int
    let results: [TMDBTVShow]
    let totalPages: Int
    let totalResults: Int

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }
}

struct TMDBTVShow: Codable {
    let id: Int
    let name: String
    let originalName: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double
    let voteCount: Int
    let popularity: Double
    let genreIds: [Int]
    let originalLanguage: String
    let originCountry: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity
        case originalName = "original_name"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case genreIds = "genre_ids"
        case originalLanguage = "original_language"
        case originCountry = "origin_country"
    }
}

struct TMDBVideosResponse: Codable {
    let id: Int
    let results: [TMDBVideo]
}

struct TMDBVideo: Codable {
    let id: String
    let key: String          // YouTube video ID
    let name: String
    let site: String         // "YouTube"
    let type: String         // "Trailer", "Clip", "Featurette", etc.
    let official: Bool
    let publishedAt: String?
    let iso639_1: String?    // Language code
    let iso3166_1: String?   // Country code

    enum CodingKeys: String, CodingKey {
        case id, key, name, site, type, official
        case publishedAt = "published_at"
        case iso639_1 = "iso_639_1"
        case iso3166_1 = "iso_3166_1"
    }

    var isYouTube: Bool {
        site.lowercased() == "youtube"
    }

    var isClipOrTrailer: Bool {
        let validTypes = ["trailer", "clip", "teaser", "featurette"]
        return validTypes.contains(type.lowercased())
    }
}

// MARK: - Genre Mapping

struct TMDBGenre {
    static let movieGenres: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
        80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
        14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Science Fiction",
        10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western"
    ]

    static let tvGenres: [Int: String] = [
        10759: "Action & Adventure", 16: "Animation", 35: "Comedy",
        80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
        10762: "Kids", 9648: "Mystery", 10763: "News", 10764: "Reality",
        10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk",
        10768: "War & Politics", 37: "Western"
    ]

    static func names(for ids: [Int], type: MediaType) -> [String] {
        let mapping = type == .movie ? movieGenres : tvGenres
        return ids.compactMap { mapping[$0] }
    }
}

enum MediaType: String, Codable {
    case movie
    case tv
}
