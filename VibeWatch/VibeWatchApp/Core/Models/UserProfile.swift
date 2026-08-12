import Foundation

/// Comprehensive user profile aggregating preferences from all app features
struct UserProfile: Codable, Sendable {
    let userId: String
    let topGenres: [GenrePreference]
    let topActors: [ActorPreference]
    let preferredMoods: [Mood]
    let watchPatterns: WatchPattern
    let contentTypePreference: ContentTypeRatio
    let recentActivity: RecentActivity

    static var empty: UserProfile {
        UserProfile(
            userId: "",
            topGenres: [],
            topActors: [],
            preferredMoods: [],
            watchPatterns: WatchPattern(),
            contentTypePreference: ContentTypeRatio(movieRatio: 0.5, tvRatio: 0.5),
            recentActivity: RecentActivity()
        )
    }
}

// MARK: - Genre Preference

struct GenrePreference: Codable, Sendable, Identifiable {
    var id: Int { genreId }
    let genreId: Int
    let genreName: String
    let totalScore: Double
    let sourceBreakdown: [String: Double] // clips, discovery, search, ai, lists

    init(genreId: Int, genreName: String, totalScore: Double, sourceBreakdown: [String: Double] = [:]) {
        self.genreId = genreId
        self.genreName = genreName
        self.totalScore = totalScore
        self.sourceBreakdown = sourceBreakdown
    }
}

// MARK: - Actor Preference

struct ActorPreference: Codable, Sendable, Identifiable {
    var id: Int { actorId }
    let actorId: Int
    let name: String
    let score: Double

    init(actorId: Int, name: String, score: Double) {
        self.actorId = actorId
        self.name = name
        self.score = score
    }
}

// MARK: - Mood

enum Mood: String, Codable, Sendable, CaseIterable {
    case happy = "happy"
    case sad = "sad"
    case excited = "excited"
    case relaxed = "relaxed"
    case scared = "scared"
    case thoughtful = "thoughtful"
    case romantic = "romantic"
    case adventurous = "adventurous"
    case nostalgic = "nostalgic"
    case energetic = "energetic"

    /// Nome inglese, per i prompt AI e i log. **Non** per la UI: lì serve `localizationKey`.
    var displayName: String {
        rawValue.capitalized
    }

    /// La chiave da risolvere quando il mood finisce a schermo.
    ///
    /// I valori tradotti sono **sostantivi** ("Adrenalina", "Nostalgia"), non aggettivi: il titolo
    /// del carosello è "Stasera: %@", e un aggettivo lì dovrebbe concordare in genere e numero con
    /// una parola che nel template non c'è. Con un sostantivo la frase regge in tutte le lingue.
    var localizationKey: String { "mood.\(rawValue)" }
}

// MARK: - Time of Day

enum TimeOfDay: String, Codable, Sendable, CaseIterable {
    case morning = "morning"     // 6 AM - 11 AM
    case afternoon = "afternoon" // 12 PM - 5 PM
    case evening = "evening"     // 6 PM - 9 PM
    case night = "night"         // 10 PM - 5 AM

    var displayName: String {
        rawValue.capitalized
    }

    var hourRange: ClosedRange<Int> {
        switch self {
        case .morning: return 6...11
        case .afternoon: return 12...17
        case .evening: return 18...21
        case .night: return 22...5
        }
    }
}

// MARK: - Watch Pattern

struct WatchPattern: Codable, Sendable {
    var preferredTimeOfDay: String? // Deprecated - use timeOfDayPreferences
    var timeOfDayPreferences: [TimeOfDay: Double]? // Preference scores per time slot
    var averageWatchDuration: TimeInterval // in seconds
    var completionRate: Double // 0.0-1.0
    var bingeWatchingFrequency: Double // 0.0-1.0

    init(
        preferredTimeOfDay: String? = nil,
        timeOfDayPreferences: [TimeOfDay: Double]? = nil,
        averageWatchDuration: TimeInterval = 0,
        completionRate: Double = 0,
        bingeWatchingFrequency: Double = 0
    ) {
        self.preferredTimeOfDay = preferredTimeOfDay
        self.timeOfDayPreferences = timeOfDayPreferences
        self.averageWatchDuration = averageWatchDuration
        self.completionRate = completionRate
        self.bingeWatchingFrequency = bingeWatchingFrequency
    }

    /// Get the most preferred time of day
    var bestTimeOfDay: TimeOfDay? {
        timeOfDayPreferences?.max(by: { $0.value < $1.value })?.key
    }

    /// Check if user prefers watching in a specific time slot
    func prefersTime(_ time: TimeOfDay, threshold: Double = 0.3) -> Bool {
        guard let score = timeOfDayPreferences?[time] else { return false }
        return score >= threshold
    }
}

// MARK: - Content Type Ratio

struct ContentTypeRatio: Codable, Sendable {
    let movieRatio: Double // 0.0-1.0
    let tvRatio: Double // 0.0-1.0

    init(movieRatio: Double, tvRatio: Double) {
        self.movieRatio = movieRatio
        self.tvRatio = tvRatio
    }
}

// MARK: - Recent Activity

struct RecentActivity: Codable, Sendable {
    var watchedMedia: [MediaSummary]
    var likedMedia: [MediaSummary]
    var lastSearchQuery: String?
    var discoveryClicks: [MediaSummary]
    var topClips: [MediaSummary]
    var watchlist: [MediaSummary]

    init(
        watchedMedia: [MediaSummary] = [],
        likedMedia: [MediaSummary] = [],
        lastSearchQuery: String? = nil,
        discoveryClicks: [MediaSummary] = [],
        topClips: [MediaSummary] = [],
        watchlist: [MediaSummary] = []
    ) {
        self.watchedMedia = watchedMedia
        self.likedMedia = likedMedia
        self.lastSearchQuery = lastSearchQuery
        self.discoveryClicks = discoveryClicks
        self.topClips = topClips
        self.watchlist = watchlist
    }
}

// MARK: - Media Summary

struct MediaSummary: Codable, Sendable, Identifiable {
    let id: Int
    let title: String
    let year: Int?
    let mediaType: MediaType

    init(id: Int, title: String, year: Int? = nil, mediaType: MediaType = .movie) {
        self.id = id
        self.title = title
        self.year = year
        self.mediaType = mediaType
    }
}

// MARK: - User Interaction

struct UserInteraction: Sendable {
    let source: InteractionSource
    let mediaId: Int?
    let mediaType: MediaType?
    let genreIds: [Int]?
    let actorIds: [Int]?
    let engagementScore: Double
    let metadata: [String: String] // Changed from [String: Any] for Sendable

    init(
        source: InteractionSource,
        mediaId: Int? = nil,
        mediaType: MediaType? = nil,
        genreIds: [Int]? = nil,
        actorIds: [Int]? = nil,
        engagementScore: Double,
        metadata: [String: String] = [:]
    ) {
        self.source = source
        self.mediaId = mediaId
        self.mediaType = mediaType
        self.genreIds = genreIds
        self.actorIds = actorIds
        self.engagementScore = engagementScore
        self.metadata = metadata
    }
}

// MARK: - Interaction Source

enum InteractionSource: String, Codable, Sendable {
    case clips
    case discovery
    case search
    case ai
    case lists
}

// MARK: - Preference Signal

struct PreferenceSignal: Sendable {
    let category: String // "genre", "actor", "director", "mood", "keyword"
    let id: String
    let name: String
    let weight: Double
    let source: InteractionSource

    init(category: String, id: String, name: String, weight: Double, source: InteractionSource) {
        self.category = category
        self.id = id
        self.name = name
        self.weight = weight
        self.source = source
    }
}

// MARK: - AI User Context

struct AIUserContext: Codable, Sendable {
    let topGenres: [String]
    let recentlyWatched: [String]
    let likedTitles: [String]
    let topActors: [String]
    let lastSearch: String?
    let recentDiscoveryClicks: [String]
    let highEngagementClips: [String]

    static var empty: AIUserContext {
        AIUserContext(
            topGenres: [],
            recentlyWatched: [],
            likedTitles: [],
            topActors: [],
            lastSearch: nil,
            recentDiscoveryClicks: [],
            highEngagementClips: []
        )
    }
}
