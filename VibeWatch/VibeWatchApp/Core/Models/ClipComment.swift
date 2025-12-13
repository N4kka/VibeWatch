import Foundation

// MARK: - Clip Comment

struct ClipComment: Codable, Identifiable {
    let id: String
    let clipId: String
    let userId: String
    let parentCommentId: String?
    var content: String
    var likeCount: Int
    var replyCount: Int
    let createdAt: Date
    var updatedAt: Date
    let deletedAt: Date?
    
    // Denormalized user info for display (not stored in DB, fetched on load)
    var userDisplayName: String?
    var userAvatarURL: String?
    
    // Client-side state
    var isLiked: Bool = false
    var replies: [ClipComment] = []
    var isExpanded: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, content
        case clipId = "clip_id"
        case userId = "user_id"
        case parentCommentId = "parent_comment_id"
        case likeCount = "like_count"
        case replyCount = "reply_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    
    init(id: String, clipId: String, userId: String, parentCommentId: String? = nil,
         content: String, likeCount: Int = 0, replyCount: Int = 0,
         createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id
        self.clipId = clipId
        self.userId = userId
        self.parentCommentId = parentCommentId
        self.content = content
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
    
    var isDeleted: Bool {
        deletedAt != nil
    }
    
    var isReply: Bool {
        parentCommentId != nil
    }
    
    var displayContent: String {
        isDeleted ? "[Comment deleted]" : content
    }
    
    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
}

// MARK: - Comment Like

struct ClipCommentLike: Codable, Identifiable {
    let id: String
    let commentId: String
    let userId: String
    let createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case commentId = "comment_id"
        case userId = "user_id"
        case createdAt = "created_at"
    }
}

// MARK: - Comment Input

struct CommentInput {
    let clipId: String
    let content: String
    let parentCommentId: String?
    
    var isReply: Bool {
        parentCommentId != nil
    }
}
