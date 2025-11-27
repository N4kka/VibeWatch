import Foundation

/// Service for managing clip reactions (likes) and comments
actor ClipCommentService {
    static let shared = ClipCommentService()
    
    private let sqlite = SQLiteService.shared
    
    // Cache for clip like counts
    private var likeCountsCache: [String: Int] = [:]
    
    private init() {}
    
    // MARK: - Clip Likes
    
    /// Get like count for a clip
    func getClipLikeCount(clipId: String) async throws -> Int {
        // Check cache first
        if let cached = likeCountsCache[clipId] {
            return cached
        }
        
        // Query from SQLite
        let result: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT COUNT(*) as count
            FROM clip_reactions
            WHERE clip_id = ? AND reaction_type = 'like'
        """, parameters: [clipId])
        
        let count = result.first?["count"] as? Int ?? 0
        
        // Cache it
        likeCountsCache[clipId] = count
        
        return count
    }
    
    /// Check if user has liked a clip
    func hasUserLikedClip(clipId: String, userId: String) async throws -> Bool {
        let result: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT id FROM clip_reactions
            WHERE clip_id = ? AND user_id = ? AND reaction_type = 'like'
        """, parameters: [clipId, userId])
        
        return !result.isEmpty
    }
    
    /// Toggle like on a clip
    func toggleClipLike(clipId: String, userId: String) async throws {
        let isLiked = try await hasUserLikedClip(clipId: clipId, userId: userId)
        
        if isLiked {
            // Remove like
            let success = sqlite.execute("""
                DELETE FROM clip_reactions
                WHERE clip_id = ? AND user_id = ? AND reaction_type = 'like'
            """, parameters: [clipId, userId])
            
            guard success else {
                throw NSError(domain: "ClipCommentService", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to remove clip like"
                ])
            }
            
            print("✅ [ClipComment] Removed like from clip \(clipId)")
            
            // Analytics
            Task { @MainActor in
                AnalyticsService.shared.logEvent(
                    "clip_like_removed",
                    parameters: ["clip_id": clipId]
                )
            }
        } else {
            // Add like
            let id = UUID().uuidString
            let now = ISO8601DateFormatter().string(from: Date())
            
            // Temporarily disable foreign key checks
            _ = sqlite.execute("PRAGMA foreign_keys = OFF")
            
            let success = sqlite.execute("""
                INSERT INTO clip_reactions (id, clip_id, user_id, reaction_type, created_at)
                VALUES (?, ?, ?, 'like', ?)
            """, parameters: [id, clipId, userId, now])
            
            // Re-enable foreign key checks
            _ = sqlite.execute("PRAGMA foreign_keys = ON")
            
            guard success else {
                throw NSError(domain: "ClipCommentService", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to add clip like"
                ])
            }
            
            print("✅ [ClipComment] Added like to clip \(clipId)")
            
            // Analytics
            Task { @MainActor in
                AnalyticsService.shared.logEvent(
                    "clip_liked",
                    parameters: ["clip_id": clipId]
                )
            }
        }
        
        // Clear cache
        likeCountsCache.removeValue(forKey: clipId)
        
        // TODO: Sync to Supabase when endpoint is ready
        print("ℹ️ [ClipComment] Supabase clip like sync not yet implemented")
    }
    
    // MARK: - Comments
    
    /// Get comments for a clip (top-level only, no replies)
    func getComments(clipId: String, userId: String? = nil, limit: Int = 50) async throws -> [ClipComment] {
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT 
                c.id, c.clip_id, c.user_id, c.parent_comment_id, c.content,
                c.like_count, c.reply_count, c.created_at, c.updated_at,
                p.display_name, p.avatar_url
            FROM clip_comments c
            LEFT JOIN profiles p ON c.user_id = p.id
            WHERE c.clip_id = ? AND c.parent_comment_id IS NULL
            ORDER BY c.created_at DESC
            LIMIT ?
        """, parameters: [clipId, limit])
        
        var comments = rows.compactMap { ClipComment.from(dictionary: $0) }
        
        // Check if current user has liked each comment
        if let userId = userId {
            for i in 0..<comments.count {
                comments[i].isLiked = try await hasUserLikedComment(
                    commentId: comments[i].id,
                    userId: userId
                )
            }
        }
        
        return comments
    }
    
    /// Get replies for a comment
    func getReplies(parentId: String, userId: String? = nil, limit: Int = 50) async throws -> [ClipComment] {
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT 
                c.id, c.clip_id, c.user_id, c.parent_comment_id, c.content,
                c.like_count, c.reply_count, c.created_at, c.updated_at,
                p.display_name, p.avatar_url
            FROM clip_comments c
            LEFT JOIN profiles p ON c.user_id = p.id
            WHERE c.parent_comment_id = ?
            ORDER BY c.created_at ASC
            LIMIT ?
        """, parameters: [parentId, limit])
        
        var replies = rows.compactMap { ClipComment.from(dictionary: $0) }
        
        // Check if current user has liked each reply
        if let userId = userId {
            for i in 0..<replies.count {
                replies[i].isLiked = try await hasUserLikedComment(
                    commentId: replies[i].id,
                    userId: userId
                )
            }
        }
        
        return replies
    }
    
    /// Post a new comment
    func postComment(clipId: String, userId: String, content: String, parentId: String? = nil) async throws -> ClipComment {
        // Ensure user profile exists in SQLite first (and update avatar if needed)
        try await ensureUserProfileExists(userId: userId)
        
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        
        // Insert comment
        // Convert nil parentId to NSNull for proper SQL NULL binding
        let parentParameter: Any = parentId != nil ? parentId! : NSNull()
        
        let success1 = sqlite.execute("""
            INSERT INTO clip_comments (
                id, clip_id, user_id, parent_comment_id, content,
                like_count, reply_count, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?)
        """, parameters: [id, clipId, userId, parentParameter, content, now, now])
        
        guard success1 else {
            throw NSError(domain: "ClipCommentService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to post comment"
            ])
        }
        
        // If this is a reply, increment parent's reply_count
        if let parentId = parentId {
            let success2 = sqlite.execute("""
                UPDATE clip_comments
                SET reply_count = reply_count + 1
                WHERE id = ?
            """, parameters: [parentId])
            
            if !success2 {
                print("⚠️ [ClipComment] Failed to increment reply count for parent \(parentId)")
            }
        }
        
        print("✅ [ClipComment] Posted comment \(id) on clip \(clipId)")
        
        // Analytics
        Task { @MainActor in
            AnalyticsService.shared.logEvent(
                parentId != nil ? "comment_reply_posted" : "comment_posted",
                parameters: [
                    "clip_id": clipId,
                    "comment_id": id,
                    "is_reply": parentId != nil
                ]
            )
        }
        
        // TODO: Sync to Supabase when endpoint is ready
        print("ℹ️ [ClipComment] Supabase comment sync not yet implemented")
        
        // Fetch and return the comment with profile info
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT 
                c.id, c.clip_id, c.user_id, c.parent_comment_id, c.content,
                c.like_count, c.reply_count, c.created_at, c.updated_at,
                p.display_name, p.avatar_url
            FROM clip_comments c
            LEFT JOIN profiles p ON c.user_id = p.id
            WHERE c.id = ?
        """, parameters: [id])
        
        guard let comment = rows.first, let clipComment = ClipComment.from(dictionary: comment) else {
            throw NSError(domain: "ClipCommentService", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to fetch created comment"
            ])
        }
        
        return clipComment
    }
    
    /// Delete a comment
    func deleteComment(commentId: String, userId: String) async throws {
        // Verify ownership
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT user_id, parent_comment_id FROM clip_comments WHERE id = ?
        """, parameters: [commentId])
        
        guard let row = rows.first else {
            throw NSError(domain: "ClipCommentService", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Comment not found"
            ])
        }
        
        guard row["user_id"] as? String == userId else {
            throw NSError(domain: "ClipCommentService", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Not authorized to delete this comment"
            ])
        }
        
        // If this is a reply, decrement parent's reply_count
        if let parentId = row["parent_comment_id"] as? String {
            let success = sqlite.execute("""
                UPDATE clip_comments
                SET reply_count = reply_count - 1
                WHERE id = ?
            """, parameters: [parentId])
            
            if !success {
                print("⚠️ [ClipComment] Failed to decrement reply count for parent \(parentId)")
            }
        }
        
        // Delete the comment
        let success = sqlite.execute("""
            DELETE FROM clip_comments WHERE id = ?
        """, parameters: [commentId])
        
        guard success else {
            throw NSError(domain: "ClipCommentService", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Failed to delete comment"
            ])
        }
        
        print("✅ [ClipComment] Deleted comment \(commentId)")
        
        // Analytics
        Task { @MainActor in
            AnalyticsService.shared.logEvent(
                "comment_deleted",
                parameters: ["comment_id": commentId]
            )
        }
        
        // TODO: Sync to Supabase when endpoint is ready
        print("ℹ️ [ClipComment] Supabase comment deletion not yet implemented")
    }
    
    // MARK: - Comment Likes
    
    /// Toggle like on a comment
    func toggleCommentLike(commentId: String, userId: String) async throws -> Bool {
        // Ensure user profile exists first
        try await ensureUserProfileExists(userId: userId)
        
        // Check if already liked
        let existingRows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT id FROM clip_comment_likes
            WHERE comment_id = ? AND user_id = ?
        """, parameters: [commentId, userId])
        
        let wasLiked = !existingRows.isEmpty
        
        if wasLiked {
            // Remove like
            let success1 = sqlite.execute("""
                DELETE FROM clip_comment_likes
                WHERE comment_id = ? AND user_id = ?
            """, parameters: [commentId, userId])
            
            guard success1 else {
                throw NSError(domain: "ClipCommentService", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to remove comment like"
                ])
            }
            
            // Decrement like count
            let success2 = sqlite.execute("""
                UPDATE clip_comments
                SET like_count = MAX(0, like_count - 1)
                WHERE id = ?
            """, parameters: [commentId])
            
            if !success2 {
                print("⚠️ [ClipComment] Failed to decrement like count for comment \(commentId)")
            }
            
            print("✅ [ClipComment] Removed like from comment \(commentId)")
        } else {
            // Add like
            let id = UUID().uuidString
            let now = ISO8601DateFormatter().string(from: Date())
            
            let success1 = sqlite.execute("""
                INSERT INTO clip_comment_likes (id, comment_id, user_id, created_at)
                VALUES (?, ?, ?, ?)
            """, parameters: [id, commentId, userId, now])
            
            guard success1 else {
                throw NSError(domain: "ClipCommentService", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to add comment like"
                ])
            }
            
            // Increment like count
            let success2 = sqlite.execute("""
                UPDATE clip_comments
                SET like_count = like_count + 1
                WHERE id = ?
            """, parameters: [commentId])
            
            if !success2 {
                print("⚠️ [ClipComment] Failed to increment like count for comment \(commentId)")
            }
            
            print("✅ [ClipComment] Added like to comment \(commentId)")
        }
        
        let isNowLiked = !wasLiked
        
        // Analytics
        Task { @MainActor in
            AnalyticsService.shared.logEvent(
                isNowLiked ? "comment_liked" : "comment_like_removed",
                parameters: ["comment_id": commentId]
            )
        }
        
        // TODO: Sync to Supabase when endpoint is ready
        print("ℹ️ [ClipComment] Supabase comment like sync not yet implemented")
        
        return isNowLiked
    }
    
    /// Check if user has liked a comment
    func hasUserLikedComment(commentId: String, userId: String) async throws -> Bool {
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT id FROM clip_comment_likes
            WHERE comment_id = ? AND user_id = ?
        """, parameters: [commentId, userId])
        
        return !rows.isEmpty
    }
    
    // MARK: - Cache Management
    
    func clearCache() {
        likeCountsCache.removeAll()
    }
    
    // MARK: - Helper Methods
    
    /// Ensure user profile exists in SQLite (required for foreign key constraints)
    private func ensureUserProfileExists(userId: String) async throws {
        // Get current user info from AuthService first
        let userInfo = await MainActor.run { () -> (String, String, String?) in
            if let currentUser = AuthService.shared.currentUser, currentUser.id == userId {
                let name = currentUser.displayName ?? "User"
                let email = currentUser.email
                let avatar = currentUser.avatarURL
                
                print("ℹ️ [ClipComment] Fetched from AuthService - name: \(name), email: \(email), avatar: \(avatar ?? "nil")")
                
                return (name, email, avatar)
            } else {
                print("⚠️ [ClipComment] No matching user in AuthService for userId: \(userId)")
                return ("User", "user@local", nil)
            }
        }
        
        let displayName = userInfo.0
        let email = userInfo.1
        let avatarURL = userInfo.2
        
        // Check if profile already exists
        let existingRows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT id, display_name, avatar_url FROM profiles WHERE id = ?
        """, parameters: [userId])
        
        if !existingRows.isEmpty {
            // Profile exists, check if it needs updating
            let existingName = existingRows.first?["display_name"] as? String
            let existingAvatar = existingRows.first?["avatar_url"] as? String
            
            print("ℹ️ [ClipComment] Profile exists - name: \(existingName ?? "nil"), avatar: \(existingAvatar ?? "nil")")
            
            // Update profile if avatar is missing/changed or display name changed
            let needsAvatarUpdate = existingAvatar != avatarURL && avatarURL != nil
            let needsNameUpdate = existingName != displayName && displayName != "User"
            
            if needsAvatarUpdate || needsNameUpdate {
                let now = ISO8601DateFormatter().string(from: Date())
                let avatarParam: Any = avatarURL ?? NSNull()
                
                let success = sqlite.execute("""
                    UPDATE profiles 
                    SET display_name = ?, avatar_url = ?, updated_at = ?
                    WHERE id = ?
                """, parameters: [displayName, avatarParam, now, userId])
                
                if success {
                    print("✅ [ClipComment] Updated profile - name: \(displayName), avatar: \(avatarURL ?? "nil")")
                } else {
                    print("⚠️ [ClipComment] Failed to update profile for user \(userId)")
                }
            }
            
            return // Profile exists
        }
        
        // Profile doesn't exist, create it
        let now = ISO8601DateFormatter().string(from: Date())
        
        // Use raw SQL insert for better control over NULL handling
        let avatarParam: Any = avatarURL ?? NSNull()
        
        let success = sqlite.execute("""
            INSERT INTO profiles (id, email, display_name, avatar_url, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, parameters: [userId, email, displayName, avatarParam, now, now])
        
        if success {
            print("✅ [ClipComment] Created profile entry for user \(userId) with name: \(displayName), avatar: \(avatarURL ?? "nil")")
        } else {
            // Profile might have been created in another thread/operation
            // Verify it exists now
            let verifyRows: [[String: Any]] = try await sqlite.queryRaw("""
                SELECT id FROM profiles WHERE id = ?
            """, parameters: [userId])
            
            if verifyRows.isEmpty {
                // Still doesn't exist, this is a real error
                print("❌ [ClipComment] Failed to create profile for user \(userId)")
                throw NSError(domain: "ClipCommentService", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create user profile"
                ])
            } else {
                print("ℹ️ [ClipComment] Profile already exists for user \(userId) (race condition)")
            }
        }
    }
}

// MARK: - ClipComment Helper

extension ClipComment {
    static func from(dictionary: [String: Any]) -> ClipComment? {
        guard
            let id = dictionary["id"] as? String,
            let clipId = dictionary["clip_id"] as? String,
            let userId = dictionary["user_id"] as? String,
            let content = dictionary["content"] as? String,
            let createdAtString = dictionary["created_at"] as? String
        else {
            return nil
        }
        
        let formatter = ISO8601DateFormatter()
        guard let createdAt = formatter.date(from: createdAtString) else {
            return nil
        }
        
        let updatedAt = (dictionary["updated_at"] as? String).flatMap { formatter.date(from: $0) } ?? createdAt
        let deletedAt = (dictionary["deleted_at"] as? String).flatMap { formatter.date(from: $0) }
        
        var comment = ClipComment(
            id: id,
            clipId: clipId,
            userId: userId,
            parentCommentId: dictionary["parent_comment_id"] as? String,
            content: content,
            likeCount: dictionary["like_count"] as? Int ?? 0,
            replyCount: dictionary["reply_count"] as? Int ?? 0,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
        
        // Add denormalized user info if available
        comment.userDisplayName = dictionary["display_name"] as? String
        comment.userAvatarURL = dictionary["avatar_url"] as? String
        
        // Debug logging
        if let displayName = comment.userDisplayName, let avatarURL = comment.userAvatarURL {
            print("📝 [ClipComment] Loaded comment with user: \(displayName), avatar: \(avatarURL)")
        } else if let displayName = comment.userDisplayName {
            print("📝 [ClipComment] Loaded comment with user: \(displayName), avatar: nil")
        } else {
            print("⚠️ [ClipComment] Loaded comment with no user info")
        }
        
        return comment
    }
}
