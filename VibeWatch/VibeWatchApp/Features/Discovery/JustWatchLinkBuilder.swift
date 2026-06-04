import Foundation

/// Pure JustWatch URL construction extracted from `MovieDetailView`.
enum JustWatchLinkBuilder {

    static func url(providerLink: String?, countryId: String, title: String) -> URL? {
        if let linkString = providerLink, let url = URL(string: linkString) {
            return url
        }

        let country = countryId.lowercased()
        let encodedQuery = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        return URL(string: "https://www.justwatch.com/\(country)/search?q=\(encodedQuery)")
    }
}
