import Foundation

/// Model to hold all discovery filter options
struct DiscoveryFilters: Equatable {
    var runtimeRange: RuntimeRange = .any
    var ratingRange: RatingRange = .any
    var country: String? = nil // ISO country code or nil for any
    var sortBy: DiscoverySortOption = .popularityDesc
    
    var isActive: Bool {
        runtimeRange != .any || ratingRange != .any || country != nil || sortBy != .popularityDesc
    }
    
    func reset() -> DiscoveryFilters {
        DiscoveryFilters()
    }
}

/// Runtime filter options (in minutes)
enum RuntimeRange: String, CaseIterable, Identifiable {
    case any
    case short
    case medium
    case long
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .any: return "filters.runtimeAny".localizedMainSafe()
        case .short: return "filters.runtimeShort".localizedMainSafe()
        case .medium: return "filters.runtimeMedium".localizedMainSafe()
        case .long: return "filters.runtimeLong".localizedMainSafe()
        }
    }
    
    var minRuntime: Int? {
        switch self {
        case .any: return nil
        case .short: return nil
        case .medium: return 90
        case .long: return 120
        }
    }
    
    var maxRuntime: Int? {
        switch self {
        case .any: return nil
        case .short: return 89
        case .medium: return 120
        case .long: return nil
        }
    }
}

/// Rating filter options
enum RatingRange: String, CaseIterable, Identifiable {
    case any
    case good
    case excellent
    case masterpiece
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .any: return "filters.ratingAny".localizedMainSafe()
        case .good: return "filters.ratingGood".localizedMainSafe()
        case .excellent: return "filters.ratingExcellent".localizedMainSafe()
        case .masterpiece: return "filters.ratingMasterpiece".localizedMainSafe()
        }
    }
    
    var minRating: Double? {
        switch self {
        case .any: return nil
        case .good: return 7.0
        case .excellent: return 8.0
        case .masterpiece: return 9.0
        }
    }
}

/// Sort options for discovery
enum DiscoverySortOption: String, CaseIterable, Identifiable, Codable {
    case popularityDesc
    case popularityAsc
    case ratingDesc
    case ratingAsc
    case releaseDateDesc
    case releaseDateAsc
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .popularityDesc: return "filters.sortPopularityDesc".localized
        case .popularityAsc: return "filters.sortPopularityAsc".localized
        case .ratingDesc: return "filters.sortRatingDesc".localized
        case .ratingAsc: return "filters.sortRatingAsc".localized
        case .releaseDateDesc: return "filters.sortReleaseDateDesc".localized
        case .releaseDateAsc: return "filters.sortReleaseDateAsc".localized
        }
    }
    
    var tmdbValue: String {
        tmdbValue(for: .movie)
    }

    func tmdbValue(for mediaType: MediaType) -> String {
        switch self {
        case .popularityDesc: return "popularity.desc"
        case .popularityAsc: return "popularity.asc"
        case .ratingDesc: return "vote_average.desc"
        case .ratingAsc: return "vote_average.asc"
        case .releaseDateDesc:
            return mediaType == .tv ? "first_air_date.desc" : "release_date.desc"
        case .releaseDateAsc:
            return mediaType == .tv ? "first_air_date.asc" : "release_date.asc"
        }
    }

    /// Free users get basic sorting options
    static var freeCases: [DiscoverySortOption] {
        [.popularityDesc, .ratingDesc]
    }
}
