import Foundation

/// Pure TMDB poster URL construction extracted from `MovieDetailView`.
enum MoviePosterShareURLBuilder {

    static func url(posterPath: String?) -> URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
}
