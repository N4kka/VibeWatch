import Foundation

// MARK: - Reaction Type

enum ReactionType: String, Codable {
    case like
    case dislike
    
    var displayName: String {
        switch self {
        case .like: return "Like"
        case .dislike: return "Dislike"
        }
    }
}

// MARK: - Movie/TV Reaction

struct MovieReaction: Codable, Identifiable {
    let id: String
    let userId: String
    let mediaId: Int
    let mediaType: MediaType
    let reactionType: ReactionType
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case mediaId = "media_id"
        case mediaType = "media_type"
        case reactionType = "reaction_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Reaction Counts

struct MovieReactionCounts: Codable {
    let mediaId: Int
    let mediaType: MediaType
    var likeCount: Int
    var dislikeCount: Int
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case mediaId = "media_id"
        case mediaType = "media_type"
        case likeCount = "like_count"
        case dislikeCount = "dislike_count"
        case updatedAt = "updated_at"
    }
    
    init(mediaId: Int, mediaType: MediaType, likeCount: Int = 0, dislikeCount: Int = 0, updatedAt: Date = Date()) {
        self.mediaId = mediaId
        self.mediaType = mediaType
        self.likeCount = likeCount
        self.dislikeCount = dislikeCount
        self.updatedAt = updatedAt
    }
    
    var totalReactions: Int {
        likeCount + dislikeCount
    }
    
    var likePercentage: Int {
        guard totalReactions > 0 else { return 0 }
        return Int((Double(likeCount) / Double(totalReactions)) * 100)
    }
}
