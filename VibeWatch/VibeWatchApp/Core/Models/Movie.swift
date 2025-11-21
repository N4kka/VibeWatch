import Foundation

struct Movie: Codable, Identifiable, Hashable {
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

struct WatchProvider: Codable {
    let results: [String: CountryProviders]?
}

struct CountryProviders: Codable {
    let link: String?
    var flatrate: [Provider]?
    var rent: [Provider]?
    var buy: [Provider]?
}

struct Provider: Codable, Identifiable, Hashable {
    let providerId: Int
    let providerName: String
    let logoPath: String
    let displayPriority: Int?
    let price: PriceInfo?
    let quality: String?
    let presentationType: String?
    
    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case providerName = "provider_name"
        case logoPath = "logo_path"
        case displayPriority = "display_priority"
        case price
        case quality
        case presentationType = "presentation_type"
    }
    
    var id: Int { providerId }
    
    var logoURL: URL? {
        URL(string: "https://image.tmdb.org/t/p/w92\(logoPath)")
    }
    
    // Format quality for display (SD, HD, 4K, etc.)
    var formattedQuality: String? {
        guard let quality = quality else { return nil }
        
        // Handle various quality format possibilities
        let uppercased = quality.uppercased()
        if uppercased.contains("4K") || uppercased.contains("UHD") {
            return "4K"
        } else if uppercased.contains("HD") || uppercased.contains("1080") {
            return "HD"
        } else if uppercased.contains("SD") || uppercased.contains("480") {
            return "SD"
        }
        
        return quality
    }
}

struct PriceInfo: Codable, Hashable {
    let value: Double?
    let currency: String?
    let formatted: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case currency
        case formatted
    }
    
    var displayPrice: String? {
        if let formatted = formatted {
            return formatted
        }
        
        if let value = value, let currency = currency {
            // Format price based on currency
            return formatPrice(value: value, currency: currency)
        }
        
        return nil
    }
    
    private func formatPrice(value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        
        if let formatted = formatter.string(from: NSNumber(value: value)) {
            return formatted
        }
        
        // Fallback
        return "\(currency) \(String(format: "%.2f", value))"
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
    
    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity, status, tagline, genres
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
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
        guard let firstAirDate = firstAirDate else { return nil }
        return String(firstAirDate.prefix(4))
    }
    
    var rating: String {
        String(format: "%.1f", voteAverage)
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
