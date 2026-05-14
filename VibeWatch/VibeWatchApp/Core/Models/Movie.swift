import Foundation

struct Movie: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double
    let voteCount: Int
    let genreIds: [Int]?
    let genres: [Genre]?
    let adult: Bool
    let originalLanguage: String
    let popularity: Double
    let runtime: Int?
    let status: String?
    let tagline: String?
    let productionCountries: [ProductionCountry]?
    let imdbId: String?
    
    enum CodingKeys: String, CodingKey {
        case id, title, overview, adult, popularity, runtime, status, tagline, genres
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case genreIds = "genre_ids"
        case originalLanguage = "original_language"
        case productionCountries = "production_countries"
        case imdbId = "imdb_id"
    }
    
    var posterURL: URL? {
        guard let posterPath = posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
    
    var backdropURL: URL? {
        guard let backdropPath = backdropPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(backdropPath)")
    }
    
    var year: String? {
        guard let releaseDate = releaseDate else { return nil }
        return String(releaseDate.prefix(4))
    }
    
    var rating: String {
        String(format: "%.1f", voteAverage)
    }
    
    var ratingPercentage: Int {
        Int(voteAverage * 10)
    }
    
    var formattedRuntime: String? {
        guard let runtime = runtime else { return nil }
        let hours = runtime / 60
        let minutes = runtime % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

struct Genre: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
}

struct ProductionCountry: Codable, Hashable {
    let iso: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case iso = "iso_3166_1"
        case name
    }
}

struct Credits: Codable {
    let cast: [Cast]
    let crew: [Crew]
}

struct Cast: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let character: String
    let profilePath: String?
    let order: Int
    
    enum CodingKeys: String, CodingKey {
        case id, name, character, order
        case profilePath = "profile_path"
    }
    
    var profileURL: URL? {
        guard let profilePath = profilePath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(profilePath)")
    }
}

struct Crew: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let job: String
    let department: String
    let profilePath: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, job, department
        case profilePath = "profile_path"
    }
}

struct Video: Codable, Identifiable, Hashable {
    let id: String
    let key: String
    let name: String
    let site: String
    let type: String
    let official: Bool?
    let size: Int?
    
    var youtubeURL: URL? {
        guard site == "YouTube" else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }
    
    var thumbnailURL: URL? {
        guard site == "YouTube" else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(key)/hqdefault.jpg")
    }
}


struct TVShow: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double
    let voteCount: Int
    let genreIds: [Int]?
    let genres: [Genre]?
    let originalLanguage: String
    let popularity: Double
    let status: String?
    let tagline: String?
    let productionCountries: [ProductionCountry]?
    let imdbId: String?
    let numberOfSeasons: Int?
    let episodeRunTime: [Int]?
    let lastAirDate: String?
    let numberOfEpisodes: Int?
    let inProduction: Bool?
    let seasons: [Season]?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity, status, tagline, genres, seasons
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case genreIds = "genre_ids"
        case originalLanguage = "original_language"
        case productionCountries = "production_countries"
        case imdbId = "imdb_id"
        case numberOfSeasons = "number_of_seasons"
        case episodeRunTime = "episode_run_time"
        case lastAirDate = "last_air_date"
        case numberOfEpisodes = "number_of_episodes"
        case inProduction = "in_production"
    }
    
    var posterURL: URL? {
        guard let posterPath = posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
    
    var backdropURL: URL? {
        guard let backdropPath = backdropPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(backdropPath)")
    }
    
    var year: String? {
        guard let firstAirDate = firstAirDate else { return nil }
        return String(firstAirDate.prefix(4))
    }

    var rating: String {
        String(format: "%.1f", voteAverage)
    }

    var ratingPercentage: Int {
        Int(voteAverage * 10)
    }

    var formattedEpisodeRuntime: String? {
        guard let first = episodeRunTime?.first, first > 0 else { return nil }
        let hours = first / 60
        let minutes = first % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }

    var airYearRange: String? {
        guard let firstAirDate, firstAirDate.count >= 4 else { return nil }
        let firstYear = String(firstAirDate.prefix(4))

        if inProduction == true {
            let currentYear = String(Calendar.current.component(.year, from: Date()))
            if let lastAirDate, lastAirDate.count >= 4 {
                let lastYear = String(lastAirDate.prefix(4))
                if lastYear < currentYear {
                    return "\(firstYear)-Present"
                }
                return lastYear == firstYear ? firstYear : "\(firstYear)-\(lastYear)"
            }
            return "\(firstYear)-Present"
        }

        guard let lastAirDate, lastAirDate.count >= 4 else { return firstYear }
        let lastYear = String(lastAirDate.prefix(4))
        return firstYear == lastYear ? firstYear : "\(firstYear)-\(lastYear)"
    }
}

struct TMDBResponse<T: Codable>: Codable {
    let page: Int
    let results: [T]
    let totalPages: Int
    let totalResults: Int
    
    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }
}

// MARK: - Sendable Conformances

extension TMDBResponse: Sendable where T: Sendable {}
extension ExternalIds: Sendable {}

struct ExternalIds: Codable {
    let imdbId: String?
    let facebookId: String?
    let instagramId: String?
    let twitterId: String?
    
    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
        case facebookId = "facebook_id"
        case instagramId = "instagram_id"
        case twitterId = "twitter_id"
    }
}
