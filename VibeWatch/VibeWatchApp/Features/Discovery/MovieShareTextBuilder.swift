import Foundation

/// Pure share-copy formatting extracted from `MovieDetailView`.
enum MovieShareTextBuilder {

    static func text(title: String, year: String?, overview: String) -> String {
        var text = "Check out \(title)"
        if let year { text += " (\(year))" }
        if !overview.isEmpty { text += "\n\n\(overview)" }
        return text
    }
}
