import Foundation

/// Pure remote-row normalization extracted from `SupabaseService.pullTable`.
enum SupabasePullRowNormalizer {

    private static let jsonArrayKeys = ["genres", "actors", "keywords", "origin_country"]

    static func normalize(row: [String: Any], table: String) -> [String: Any] {
        var normalized = row

        if table == "clips" || table == "list_items" {
            if let mediaType = normalized["media_type"] as? String, !["movie", "tv"].contains(mediaType) {
                normalized["media_type"] = "movie"
            }
        }

        for key in jsonArrayKeys {
            normalizeArray(key, in: &normalized)
        }

        return normalized
    }

    private static func normalizeArray(_ key: String, in row: inout [String: Any]) {
        guard let array = row[key] as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: array),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        row[key] = string
    }
}
