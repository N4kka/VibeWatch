import Foundation

private let personBirthdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

struct PersonDetails: Codable {
    let id: Int
    let name: String
    let biography: String
    let profilePath: String?
    let birthday: String?
    let placeOfBirth: String?
    let deathday: String?

    enum CodingKeys: String, CodingKey {
        case id, name, biography
        case profilePath = "profile_path"
        case birthday
        case placeOfBirth = "place_of_birth"
        case deathday
    }

    var profileURL: URL? {
        guard let profilePath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w300\(profilePath)")
    }

    var birthdayDate: Date? {
        guard let birthday else { return nil }
        return personBirthdayFormatter.date(from: birthday)
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
    let popularity: Double?
    let voteAverage: Double?
    let overview: String?

    enum CodingKeys: String, CodingKey {
        case id
        case mediaType = "media_type"
        case title, character
        case name
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case popularity
        case voteAverage = "vote_average"
        case overview
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
        popularity = try container.decodeIfPresent(Double.self, forKey: .popularity)
        voteAverage = try container.decodeIfPresent(Double.self, forKey: .voteAverage)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encodeIfPresent(character, forKey: .character)
        try container.encodeIfPresent(posterPath, forKey: .posterPath)
        try container.encodeIfPresent(popularity, forKey: .popularity)
        try container.encodeIfPresent(voteAverage, forKey: .voteAverage)
        try container.encodeIfPresent(overview, forKey: .overview)

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

    var posterURL342: URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
    }

    var year: String? {
        guard let releaseDate, let year = releaseDate.split(separator: "-").first else { return nil }
        return String(year)
    }

    /// Il minimo che serve per salvare in watchlist o iscriversi agli avvisi da una filmografia:
    /// una scheda credito non porta con sé backdrop, generi o runtime.
    func asMovie() -> Movie {
        Movie(
            id: id,
            title: title,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: nil,
            releaseDate: releaseDate,
            voteAverage: voteAverage ?? 0.0,
            voteCount: 0,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: popularity ?? 0.0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }
}
