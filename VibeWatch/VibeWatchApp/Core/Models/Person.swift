import Foundation

struct PersonDetails: Codable {
    let id: Int
    let name: String
    let biography: String
    let profilePath: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, biography
        case profilePath = "profile_path"
    }
    
    var profileURL: URL? {
        guard let profilePath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w300\(profilePath)")
    }
}

struct PersonCombinedCredits: Codable {
    let cast: [PersonCredit]
}

struct PersonCredit: Codable, Identifiable, Hashable {
    let id: Int
    let mediaType: MediaType
    let title: String
    let character: String?
    let posterPath: String?
    let releaseDate: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case mediaType = "media_type"
        case title, character
        case name
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        
        if mediaType == .movie {
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        } else {
            title = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            releaseDate = try container.decodeIfPresent(String.self, forKey: .firstAirDate)
        }
        
        character = try container.decodeIfPresent(String.self, forKey: .character)
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encodeIfPresent(character, forKey: .character)
        try container.encodeIfPresent(posterPath, forKey: .posterPath)
        
        switch mediaType {
        case .movie:
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        case .tv:
            try container.encode(title, forKey: .name)
            try container.encodeIfPresent(releaseDate, forKey: .firstAirDate)
        }
    }
    
    var posterURL: URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(posterPath)")
    }
    
    var year: String? {
        guard let releaseDate, let year = releaseDate.split(separator: "-").first else { return nil }
        return String(year)
    }
}
