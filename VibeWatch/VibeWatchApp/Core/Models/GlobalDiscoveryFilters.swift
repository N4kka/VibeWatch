import Foundation

/// Global discovery filters that apply to ALL carousels in Discovery tab
/// Persists across sessions via UserDefaults
struct GlobalDiscoveryFilters: Codable, Equatable {
    // Media Type
    var mediaType: MediaTypeFilter = .both

    // Runtime (Free: presets, Pro: custom range)
    var runtimePreset: RuntimePreset = .any
    var customRuntimeMin: Int? = nil
    var customRuntimeMax: Int? = nil

    // Rating (Free: presets, Pro: custom range)
    var ratingPreset: RatingPreset = .any
    var customRatingMin: Double? = nil
    var customRatingMax: Double? = nil

    // Release Period (Free: presets, Pro: custom year range)
    var releasePeriodPreset: ReleasePeriodPreset = .any
    var customYearStart: Int? = nil
    var customYearEnd: Int? = nil

    // Country (Free: top 10 single-select, Pro: multi-select)
    var countries: [String] = [] // ISO country codes

    // Streaming Platforms
    var streamingPlatforms: Set<String> = []

    // Sort By (Free: basic options, Pro: advanced)
    var sortBy: DiscoverySortOption = .popularityDesc

    // Pro Only
    var hideWatched: Bool = false
    var hideDisliked: Bool = false

    /// Check if any filters are active
    var isActive: Bool {
        mediaType != .both ||
        runtimePreset != .any ||
        ratingPreset != .any ||
        releasePeriodPreset != .any ||
        !countries.isEmpty ||
        !streamingPlatforms.isEmpty ||
        sortBy != .popularityDesc ||
        hideWatched ||
        hideDisliked
    }

    /// Count of active filters for badge display
    var activeFilterCount: Int {
        var count = 0
        if mediaType != .both { count += 1 }
        if runtimePreset != .any || customRuntimeMin != nil || customRuntimeMax != nil { count += 1 }
        if ratingPreset != .any || customRatingMin != nil || customRatingMax != nil { count += 1 }
        if releasePeriodPreset != .any || customYearStart != nil || customYearEnd != nil { count += 1 }
        if !countries.isEmpty { count += 1 }
        if !streamingPlatforms.isEmpty { count += 1 }
        if sortBy != .popularityDesc { count += 1 }
        if hideWatched { count += 1 }
        if hideDisliked { count += 1 }
        return count
    }

    // MARK: - TMDB API Parameter Mapping

    /// Get actual runtime range for API calls
    func getRuntimeRange() -> (min: Int?, max: Int?) {
        if runtimePreset == .custom {
            return (customRuntimeMin, customRuntimeMax)
        } else {
            return (runtimePreset.minRuntime, runtimePreset.maxRuntime)
        }
    }

    /// Get actual rating range for API calls
    func getRatingRange() -> (min: Double?, max: Double?) {
        if ratingPreset == .custom {
            return (customRatingMin, customRatingMax)
        } else {
            return (ratingPreset.minRating, nil)
        }
    }

    /// Get actual year range for API calls
    func getYearRange() -> (start: Int?, end: Int?) {
        if releasePeriodPreset == .custom {
            return (customYearStart, customYearEnd)
        } else {
            return (releasePeriodPreset.yearStart, releasePeriodPreset.yearEnd)
        }
    }

    // MARK: - Persistence

    private static let storageKey = "GlobalDiscoveryFilters"

    /// Load filters from UserDefaults
    static func load() -> GlobalDiscoveryFilters {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let filters = try? JSONDecoder().decode(GlobalDiscoveryFilters.self, from: data) else {
            return GlobalDiscoveryFilters()
        }
        return filters
    }

    /// Save filters to UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: GlobalDiscoveryFilters.storageKey)
        }
    }
}

// MARK: - Media Type Filter

enum MediaTypeFilter: String, Codable, CaseIterable, Identifiable {
    case movies
    case tvShows
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .movies: return "filters.movies".localized
        case .tvShows: return "filters.tvShows".localized
        case .both: return "filters.both".localized
        }
    }
}

// MARK: - Runtime Presets

enum RuntimePreset: String, Codable, CaseIterable, Identifiable {
    case any
    case short // < 90 min
    case medium // 90-120 min
    case long // > 120 min
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return "filters.runtimeAny".localized
        case .short: return "filters.runtimeShort".localized
        case .medium: return "filters.runtimeMedium".localized
        case .long: return "filters.runtimeLong".localized
        case .custom: return "filters.custom".localized
        }
    }

    var minRuntime: Int? {
        switch self {
        case .any, .short, .custom: return nil
        case .medium: return 90
        case .long: return 120
        }
    }

    var maxRuntime: Int? {
        switch self {
        case .any, .long, .custom: return nil
        case .short: return 89
        case .medium: return 120
        }
    }
}

// MARK: - Rating Presets

enum RatingPreset: String, Codable, CaseIterable, Identifiable {
    case any
    case good // 7+
    case excellent // 8+
    case masterpiece // 9+
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return "filters.ratingAny".localized
        case .good: return "filters.ratingGood".localized // "Good (7+)"
        case .excellent: return "filters.ratingExcellent".localized // "Excellent (8+)"
        case .masterpiece: return "filters.ratingMasterpiece".localized // "Masterpiece (9+)"
        case .custom: return "filters.custom".localized
        }
    }

    var minRating: Double? {
        switch self {
        case .any, .custom: return nil
        case .good: return 7.0
        case .excellent: return 8.0
        case .masterpiece: return 9.0
        }
    }
}

// MARK: - Release Period Presets

enum ReleasePeriodPreset: String, Codable, CaseIterable, Identifiable {
    case any
    case recent // 2020+
    case modern // 2010-2019
    case classic // < 2010
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return "filters.releasePeriodAny".localized
        case .recent: return "filters.releasePeriodRecent".localized // "Recent (2020+)"
        case .modern: return "filters.releasePeriodModern".localized // "Modern (2010-2019)"
        case .classic: return "filters.releasePeriodClassic".localized // "Classic (<2010)"
        case .custom: return "filters.custom".localized
        }
    }

    var yearStart: Int? {
        switch self {
        case .any, .custom: return nil
        case .recent: return 2020
        case .modern: return 2010
        case .classic: return nil
        }
    }

    var yearEnd: Int? {
        switch self {
        case .any, .custom: return nil
        case .recent: return nil
        case .modern: return 2019
        case .classic: return 2009
        }
    }
}

// MARK: - Country Filter

struct CountryFilter {
    let code: String
    let name: String
    let flag: String

    /// Top 10 countries for free users
    static let topCountries: [CountryFilter] = [
        CountryFilter(code: "US", name: "United States", flag: "🇺🇸"),
        CountryFilter(code: "GB", name: "United Kingdom", flag: "🇬🇧"),
        CountryFilter(code: "FR", name: "France", flag: "🇫🇷"),
        CountryFilter(code: "DE", name: "Germany", flag: "🇩🇪"),
        CountryFilter(code: "IT", name: "Italy", flag: "🇮🇹"),
        CountryFilter(code: "ES", name: "Spain", flag: "🇪🇸"),
        CountryFilter(code: "JP", name: "Japan", flag: "🇯🇵"),
        CountryFilter(code: "KR", name: "South Korea", flag: "🇰🇷"),
        CountryFilter(code: "IN", name: "India", flag: "🇮🇳"),
        CountryFilter(code: "CA", name: "Canada", flag: "🇨🇦")
    ]

    /// All countries for Pro users
    static let allCountries: [CountryFilter] = topCountries + [
        CountryFilter(code: "AU", name: "Australia", flag: "🇦🇺"),
        CountryFilter(code: "BR", name: "Brazil", flag: "🇧🇷"),
        CountryFilter(code: "MX", name: "Mexico", flag: "🇲🇽"),
        CountryFilter(code: "CN", name: "China", flag: "🇨🇳"),
        CountryFilter(code: "RU", name: "Russia", flag: "🇷🇺"),
        CountryFilter(code: "SE", name: "Sweden", flag: "🇸🇪"),
        CountryFilter(code: "NO", name: "Norway", flag: "🇳🇴"),
        CountryFilter(code: "DK", name: "Denmark", flag: "🇩🇰"),
        CountryFilter(code: "FI", name: "Finland", flag: "🇫🇮"),
        CountryFilter(code: "NL", name: "Netherlands", flag: "🇳🇱"),
        CountryFilter(code: "BE", name: "Belgium", flag: "🇧🇪"),
        CountryFilter(code: "CH", name: "Switzerland", flag: "🇨🇭"),
        CountryFilter(code: "AT", name: "Austria", flag: "🇦🇹"),
        CountryFilter(code: "PL", name: "Poland", flag: "🇵🇱"),
        CountryFilter(code: "TR", name: "Turkey", flag: "🇹🇷"),
        CountryFilter(code: "GR", name: "Greece", flag: "🇬🇷"),
        CountryFilter(code: "PT", name: "Portugal", flag: "🇵🇹"),
        CountryFilter(code: "IE", name: "Ireland", flag: "🇮🇪"),
        CountryFilter(code: "NZ", name: "New Zealand", flag: "🇳🇿"),
        CountryFilter(code: "SG", name: "Singapore", flag: "🇸🇬"),
        CountryFilter(code: "TH", name: "Thailand", flag: "🇹🇭"),
        CountryFilter(code: "AR", name: "Argentina", flag: "🇦🇷"),
        CountryFilter(code: "CL", name: "Chile", flag: "🇨🇱"),
        CountryFilter(code: "CO", name: "Colombia", flag: "🇨🇴"),
        CountryFilter(code: "ZA", name: "South Africa", flag: "🇿🇦"),
        CountryFilter(code: "EG", name: "Egypt", flag: "🇪🇬"),
        CountryFilter(code: "ID", name: "Indonesia", flag: "🇮🇩"),
        CountryFilter(code: "MY", name: "Malaysia", flag: "🇲🇾"),
        CountryFilter(code: "PH", name: "Philippines", flag: "🇵🇭"),
        CountryFilter(code: "VN", name: "Vietnam", flag: "🇻🇳")
    ]

    /// Find country by code
    static func find(by code: String?) -> CountryFilter? {
        guard let code = code else { return nil }
        return allCountries.first { $0.code == code }
    }
}
