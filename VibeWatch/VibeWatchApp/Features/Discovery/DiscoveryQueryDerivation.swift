import Foundation

/// Pure derivation of discovery-query parameters from user preferences and filters.
///
/// Extracted verbatim from `DiscoveryPersonalizationService` (`inferDecade`,
/// `moodToGenreIds`, `yearDateRange`) so the mapping from taste/filters to TMDB query
/// inputs can be unit-tested without the service (Fase 5 file-splitting, same approach as
/// `DiscoveryRanking`). Behavior preserved exactly.
enum DiscoveryQueryDerivation {

    /// Average release decade of the liked media, rounded down to the decade.
    /// Falls back to 2010 when there are no dated items.
    static func inferDecade(from likedMedia: [MediaSummary]) -> Int {
        let years = likedMedia.compactMap { $0.year }
        guard !years.isEmpty else { return 2010 }
        let avgYear = years.reduce(0, +) / years.count
        return (avgYear / 10) * 10
    }

    /// TMDB genre IDs associated with a mood.
    static func moodToGenreIds(_ mood: Mood) -> [Int] {
        switch mood {
        case .happy: return [35, 10751]
        case .sad: return [18]
        case .excited: return [28, 12]
        case .relaxed: return [35, 10749]
        case .scared: return [27, 53]
        case .thoughtful: return [18, 99]
        case .romantic: return [10749, 18]
        case .adventurous: return [12, 28]
        case .nostalgic: return [36, 10751]
        case .energetic: return [28, 878]
        }
    }

    /// Convert a filter year range into TMDB `primary_release_date` bounds (`gte`/`lte`).
    static func yearDateRange(filters: GlobalDiscoveryFilters) -> (gte: String?, lte: String?) {
        let yearRange = filters.getYearRange()
        let gte = yearRange.start.map { "\($0)-01-01" }
        let lte = yearRange.end.map { "\($0)-12-31" }
        return (gte, lte)
    }
}
