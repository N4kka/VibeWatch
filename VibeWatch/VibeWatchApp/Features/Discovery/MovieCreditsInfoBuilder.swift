import Foundation

/// Pure information-row mapping extracted from `MovieDetailView`.
enum MovieCreditsInfoBuilder {

    struct Row: Equatable {
        let titleKey: String
        let value: String
    }

    static func rows(movie: Movie, director: Crew?) -> [Row] {
        var rows: [Row] = []

        if movie.ratingPercentage > 0 {
            rows.append(Row(titleKey: "movieDetail.rating", value: "\(movie.ratingPercentage)%"))
        }

        if let genres = movie.genres, !genres.isEmpty {
            rows.append(Row(titleKey: "movieDetail.genres", value: genres.map { $0.name }.joined(separator: ", ")))
        }

        if let runtime = movie.formattedRuntime {
            rows.append(Row(titleKey: "movieDetail.runtime", value: runtime))
        }

        if let countries = movie.productionCountries, !countries.isEmpty {
            rows.append(Row(titleKey: "movieDetail.country", value: countries.first?.name ?? ""))
        }

        if let director {
            rows.append(Row(titleKey: "movieDetail.director", value: director.name))
        }

        return rows
    }
}
