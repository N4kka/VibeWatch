import Foundation

/// I tre scope di `get_activity_feed`: chi seguo, tutti, un profilo (`user` vuole `p_user`).
enum ActivityFeedScope: String, CaseIterable {
    case following
    case community
    case user

    /// La fotografia offline è per i due feed del tab Social, che sono sempre gli stessi due.
    /// `user` no: la cache è indicizzata per scope, e una sola riga "user" finirebbe per servire
    /// l'attività di Anna sul profilo di Bruno — un errore peggiore del vuoto che eviterebbe.
    var isCacheable: Bool { self != .user }
}

/// I tipi di card che il server aggrega in `activities`. L'enum è chiuso di proposito: un tipo
/// nuovo arriva insieme a una versione dell'app che sa disegnarlo, e un feed che decodifica
/// "qualcosa" senza saperlo mostrare è una card rotta, non una feature.
enum ActivityType: String, Codable, Equatable {
    case watched
    case rated
    case listCreated = "list_created"
    case showCompleted = "show_completed"
}

/// Una riga di `get_activity_feed`, già pronta per la card del feed. Codable nei due versi:
/// Decodable per la RPC, Encodable perché `activity_feed_cache` conserva la riga com'è.
struct ActivityItem: Identifiable, Equatable, Codable {
    let id: UUID
    let userId: UUID
    let username: String?
    let displayName: String?
    let avatarUrl: String?
    let activityType: ActivityType
    let mediaType: String?
    let tmdbId: Int?
    let episodeCount: Int?
    /// 1-10 in mezze stelle, identico a `user_ratings` (nil se la card non porta un voto).
    let rating: Int?
    let reviewId: UUID?
    let reviewContent: String?
    let containsSpoilers: Bool?
    let listId: UUID?
    let listName: String?
    let listCoverPosterPaths: [String]?
    let title: String?
    let posterPath: String?
    let occurredAt: Date
    let likeCount: Int
    let commentCount: Int
    let likedByMe: Bool

    enum CodingKeys: String, CodingKey {
        case id = "activity_id"
        case userId = "user_id"
        case username
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case activityType = "activity_type"
        case mediaType = "media_type"
        case tmdbId = "tmdb_id"
        case episodeCount = "episode_count"
        case rating
        case reviewId = "review_id"
        case reviewContent = "review_content"
        case containsSpoilers = "contains_spoilers"
        case listId = "list_id"
        case listName = "list_name"
        case listCoverPosterPaths = "list_cover_poster_paths"
        case title
        case posterPath = "poster_path"
        case occurredAt = "occurred_at"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case likedByMe = "liked_by_me"
    }
}
