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
        case .any: return "filters.runtimeAny".localized
        case .short: return "filters.runtimeShort".localized
        case .medium: return "filters.runtimeMedium".localized
        case .long: return "filters.runtimeLong".localized
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
        case .any: return "filters.ratingAny".localized
        case .good: return "filters.ratingGood".localized
        case .excellent: return "filters.ratingExcellent".localized
        case .masterpiece: return "filters.ratingMasterpiece".localized
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
enum DiscoverySortOption: String, CaseIterable, Identifiable {
    case popularityDesc
    case popularityAsc
    case ratingDesc
    case ratingAsc
    case releaseDateDesc
    case releaseDateAsc
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .popularityDesc: return "sort.popularityDesc".localized
        case .popularityAsc: return "sort.popularityAsc".localized
        case .ratingDesc: return "sort.ratingDesc".localized
        case .ratingAsc: return "sort.ratingAsc".localized
        case .releaseDateDesc: return "sort.releaseDateDesc".localized
        case .releaseDateAsc: return "sort.releaseDateAsc".localized
        }
    }
    
    var tmdbValue: String {
        switch self {
        case .popularityDesc: return "popularity.desc"
        case .popularityAsc: return "popularity.asc"
        case .ratingDesc: return "vote_average.desc"
        case .ratingAsc: return "vote_average.asc"
        case .releaseDateDesc: return "release_date.desc"
        case .releaseDateAsc: return "release_date.asc"
        }
    }
}
