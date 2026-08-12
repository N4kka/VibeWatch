import Foundation

struct Season: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let overview: String
    let posterPath: String?
    let seasonNumber: Int
    let airDate: String?
    let episodeCount: Int
    let voteAverage: Double

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case posterPath = "poster_path"
        case seasonNumber = "season_number"
        case airDate = "air_date"
        case episodeCount = "episode_count"
        case voteAverage = "vote_average"
    }

    var posterURL: URL? {
        guard let path = posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    var year: String? {
        guard let airDate, airDate.count >= 4 else { return nil }
        return String(airDate.prefix(4))
    }
}

struct SeasonDetail: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let overview: String
    let posterPath: String?
    let seasonNumber: Int
    let airDate: String?
    let voteAverage: Double
    let episodes: [Episode]

    enum CodingKeys: String, CodingKey {
        case id, name, overview, episodes
        case posterPath = "poster_path"
        case seasonNumber = "season_number"
        case airDate = "air_date"
        case voteAverage = "vote_average"
    }

    var posterURL: URL? {
        guard let path = posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    var year: String? {
        guard let airDate, airDate.count >= 4 else { return nil }
        return String(airDate.prefix(4))
    }

    var episodeCount: Int { episodes.count }
}

struct Episode: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let overview: String
    let episodeNumber: Int
    let seasonNumber: Int
    let airDate: String?
    let runtime: Int?
    let voteAverage: Double
    let voteCount: Int
    let stillPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, runtime
        case episodeNumber = "episode_number"
        case seasonNumber = "season_number"
        case airDate = "air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case stillPath = "still_path"
    }

    var stillURL: URL? {
        guard let path = stillPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    var airDateFormatted: String? {
        guard let airDate, airDate.count >= 10 else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: airDate) else { return nil }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    var formattedRuntime: String? {
        guard let runtime else { return nil }
        let hours = runtime / 60
        let minutes = runtime % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
