import Foundation
import Supabase

/// Service for managing clip reactions (likes) and comments
@MainActor
final class ClipCommentService: ObservableObject {
    static let shared = ClipCommentService()
    
    private let sqlite = SQLiteService.shared
    private let supabase = SupabaseService.shared
    private let isoFormatter = ISO8601DateFormatter()
    private struct SendableDictionary: @unchecked Sendable { var raw: [String: Any] }
    // Added: wrapper to safely send arrays of dictionaries across actors
    private struct SendableArrayOfDictionaries: @unchecked Sendable { let raw: [[String: Any]] }
    
    // Guard to avoid spamming failing RPCs when backend schema is outdated
    private var commentRPCDisabled = false
    
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
    func toggleClipLike(
        clipId: String,
        userId: String,
        context: AnalyticsContext? = nil
    ) async throws {
        try await ensureUserProfileExists(userId: userId)
        
        let wasLiked = try await hasUserLikedClip(clipId: clipId, userId: userId)
        let reactionId = try await existingClipReactionId(clipId: clipId, userId: userId) ?? UUID().uuidString
        let nowLiked = !wasLiked
        let now = isoFormatter.string(from: Date())
        
        // Apply locally first
        _ = try await setClipLiked(
            clipId: clipId,
            userId: userId,
            liked: nowLiked,
            reactionId: reactionId,
            markSynced: false
        )
        likeCountsCache.removeValue(forKey: clipId)
        
        // Try Supabase; queue outbox if it fails
        if let remoteResult = await supabaseToggleClipLike(clipId: clipId, reactionId: reactionId) {
            // Reconcile with remote truth
            if remoteResult.liked != nowLiked {
                _ = try await setClipLiked(
                    clipId: clipId,
                    userId: userId,
                    liked: remoteResult.liked,
                    reactionId: reactionId,
                    markSynced: false
                )
            }
            await setLocalClipLikeCount(clipId: clipId, count: remoteResult.like_count)
            likeCountsCache[clipId] = remoteResult.like_count
            markSynced(table: "clip_reactions", recordId: reactionId)
            print("☁️ [ClipComment] Synced clip like to Supabase (liked: \(remoteResult.liked))")
        } else {
            let payload: [String: Any] = [
                "id": reactionId,
                "clip_id": clipId,
                "user_id": userId,
                "reaction_type": "like",
                "created_at": now,
                "updated_at": now
            ]
            await queueOutbox(
                userId: userId,
                tableName: "clip_reactions",
                operation: nowLiked ? "INSERT" : "DELETE",
                recordId: reactionId,
                payload: payload
            )
            print("📦 [ClipComment] Applied clip like locally and queued sync")
        }
        
        // Analytics
        Task { @MainActor in
            AnalyticsService.shared.logEventWithContext(
                nowLiked ? "clip_liked" : "clip_like_removed",
                parameters: ["clip_id": clipId],
                context: context
            )
            await SupabaseService.shared.logClipSignal(
                clipId: clipId,
                signalType: "like",
                signalValue: nowLiked ? 1 : -1,
                context: context
            )
        }
    }
    
    // MARK: - Comments
    
    /// Get comments for a clip (top-level only, no replies)
    func getComments(clipId: String, userId: String? = nil, limit: Int = 50) async throws -> [ClipComment] {
        // Prefer fresh data from Supabase when authenticated
        _ = await syncCommentsFromSupabase(clipId: clipId, userId: userId, limit: limit, includeReplies: false)
        
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT 
                c.id, c.clip_id, c.user_id, c.parent_comment_id, c.content,
                c.like_count, c.reply_count, c.created_at, c.updated_at,
                p.display_name, p.avatar_url
            FROM clip_comments c
            LEFT JOIN profiles p ON c.user_id = p.id
            WHERE c.clip_id = ? AND c.parent_comment_id IS NULL AND c.deleted_at IS NULL
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
        // Attempt to refresh from Supabase if available
        _ = await syncRepliesFromSupabase(parentId: parentId, userId: userId, limit: limit)
        
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT 
                c.id, c.clip_id, c.user_id, c.parent_comment_id, c.content,
                c.like_count, c.reply_count, c.created_at, c.updated_at,
                p.display_name, p.avatar_url
            FROM clip_comments c
            LEFT JOIN profiles p ON c.user_id = p.id
            WHERE c.parent_comment_id = ? AND c.deleted_at IS NULL
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
    func postComment(
        clipId: String,
        userId: String,
        content: String,
        parentId: String? = nil,
        context: AnalyticsContext? = nil
    ) async throws -> ClipComment {
        // Ensure user profile exists in SQLite first (and update avatar if needed)
        try await ensureUserProfileExists(userId: userId)
        
        let now = isoFormatter.string(from: Date())
        // Capture only Sendable data outside the transaction
        let parentIdParam: String? = parentId
        let commentId = UUID().uuidString
        
        try await sqlite.transaction {
            // Build Any/NSNull inside the @Sendable closure to avoid capturing non-Sendable Any
            let parentSQLParam: Any = parentIdParam ?? NSNull()
            
            let success = sqlite.execute("""
                INSERT OR REPLACE INTO clip_comments (
                    id, clip_id, user_id, parent_comment_id, content,
                    like_count, reply_count, created_at, updated_at, synced_at
                ) VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?, NULL)
            """, parameters: [commentId, clipId, userId, parentSQLParam, content, now, now])
            
            if !success {
                throw NSError(domain: "ClipCommentService", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to post comment"
                ])
            }
            
            if let parentId = parentIdParam {
                let success2 = sqlite.execute("""
                    UPDATE clip_comments
                    SET reply_count = reply_count + 1
                    WHERE id = ?
                """, parameters: [parentId])
                
                if !success2 {
                    print("⚠️ [ClipComment] Failed to increment reply count for parent \(parentId)")
                }
            }
        }
        
        adjustLocalClipCommentCount(clipId: clipId, delta: 1)
        
        var clipComment = try await loadComment(commentId: commentId)
        if clipComment.userDisplayName == nil || clipComment.userAvatarURL == nil {
            let userInfo = await MainActor.run { AuthService.shared.currentUser }
            clipComment.userDisplayName = userInfo?.displayName ?? clipComment.userDisplayName
            clipComment.userAvatarURL = userInfo?.avatarURL ?? clipComment.userAvatarURL
        }
        
        // Try Supabase after local commit; queue sync if it fails
        if let remoteComment = await supabaseAddComment(
            clipId: clipId,
            content: content,
            parentId: parentId,
            commentId: commentId
        ) {
            markSynced(table: "clip_comments", recordId: remoteComment.id)
            print("☁️ [ClipComment] Posted comment to Supabase for clip \(clipId)")
            clipComment = remoteComment
        } else {
            let payload: [String: Any] = [
                "id": commentId,
                "clip_id": clipId,
                "user_id": userId,
                "parent_comment_id": parentId ?? NSNull(),
                "content": content,
                "like_count": 0,
                "reply_count": 0,
                "created_at": now,
                "updated_at": now
            ]
            
            await queueOutbox(
                userId: userId,
                tableName: "clip_comments",
                operation: "INSERT",
                recordId: commentId,
                payload: payload
            )
            print("📦 [ClipComment] Posted comment locally and queued sync for clip \(clipId)")
        }
        
        // Analytics & Gamification
        Task { @MainActor in
            AnalyticsService.shared.logEventWithContext(
                parentId != nil ? "comment_reply_posted" : "comment_posted",
                parameters: [
                    "clip_id": clipId,
                    "comment_id": commentId,
                    "is_reply": parentId != nil
                ],
                context: context
            )
            await SupabaseService.shared.logClipSignal(
                clipId: clipId,
                signalType: parentId != nil ? "comment_reply" : "comment",
                signalValue: 1,
                context: context
            )

            // Award gamification XP for posting comment
            let isPro = await ClipQuotaService.shared.checkIsProUser()
            _ = await GamificationService.shared.awardXP(userId: userId, action: .commentPosted, isPro: isPro)
        }

        return clipComment
    }
    
    /// Delete a comment
    func deleteComment(
        commentId: String,
        userId: String,
        context: AnalyticsContext? = nil
    ) async throws {
        // Verify ownership
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT user_id, parent_comment_id, clip_id FROM clip_comments WHERE id = ?
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
        
        let parentId = row["parent_comment_id"] as? String
        let clipId = row["clip_id"] as? String ?? ""
        let now = isoFormatter.string(from: Date())
        
        try await sqlite.transaction {
            _ = sqlite.execute("""
                UPDATE clip_comments
                SET deleted_at = ?, updated_at = ?, synced_at = NULL
                WHERE id = ?
            """, parameters: [now, now, commentId])
            
            if let parentId = parentId {
                let success = sqlite.execute("""
                    UPDATE clip_comments
                    SET reply_count = MAX(0, reply_count - 1)
                    WHERE id = ?
                """, parameters: [parentId])
                
                if !success {
                    print("⚠️ [ClipComment] Failed to decrement reply count for parent \(parentId)")
                }
            }
        }
        
        adjustLocalClipCommentCount(clipId: clipId, delta: -1)
        
        // Try remote; queue if it fails
        if await supabaseDeleteComment(commentId: commentId) {
            markSynced(table: "clip_comments", recordId: commentId)
            print("☁️ [ClipComment] Deleted comment \(commentId) remotely")
        } else {
            await queueOutbox(
                userId: userId,
                tableName: "clip_comments",
                operation: "DELETE",
                recordId: commentId,
                payload: ["id": commentId, "clip_id": clipId, "deleted_at": now]
            )
            print("📦 [ClipComment] Soft-deleted comment locally and queued remote delete")
        }
        
        // Analytics
        Task { @MainActor in
            AnalyticsService.shared.logEventWithContext(
                "comment_deleted",
                parameters: ["comment_id": commentId, "clip_id": clipId],
                context: context
            )
        }
    }
    
    // MARK: - Comment Likes
    
    /// Toggle like on a comment
    func toggleCommentLike(
        commentId: String,
        userId: String,
        context: AnalyticsContext? = nil
    ) async throws -> Bool {
        // Ensure user profile exists first
        try await ensureUserProfileExists(userId: userId)
        
        let wasLiked = try await hasUserLikedComment(commentId: commentId, userId: userId)
        let likeId = try await existingCommentLikeId(commentId: commentId, userId: userId) ?? UUID().uuidString
        let nowLiked = !wasLiked
        let now = isoFormatter.string(from: Date())
        
        _ = try await setCommentLiked(
            commentId: commentId,
            userId: userId,
            liked: nowLiked,
            likeId: likeId,
            remoteLikeCount: nil,
            markSynced: false
        )
        
        if let remoteResult = await supabaseToggleCommentLike(commentId: commentId, likeId: likeId) {
            _ = try await setCommentLiked(
                commentId: commentId,
                userId: userId,
                liked: remoteResult.liked,
                likeId: likeId,
                remoteLikeCount: remoteResult.like_count,
                markSynced: true
            )
            markSynced(table: "clip_comment_likes", recordId: likeId)
            markSynced(table: "clip_comments", recordId: commentId)
            print("☁️ [ClipComment] Synced comment like to Supabase (liked: \(remoteResult.liked))")
        } else {
            let payload: [String: Any] = [
                "id": likeId,
                "comment_id": commentId,
                "user_id": userId,
                "created_at": now
            ]
            await queueOutbox(
                userId: userId,
                tableName: "clip_comment_likes",
                operation: nowLiked ? "INSERT" : "DELETE",
                recordId: likeId,
                payload: payload
            )
            print("📦 [ClipComment] Toggled comment like locally and queued sync")
        }
        
        // Analytics
        Task { @MainActor in
            AnalyticsService.shared.logEventWithContext(
                nowLiked ? "comment_liked" : "comment_like_removed",
                parameters: ["comment_id": commentId],
                context: context
            )
        }
        
        return nowLiked
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
    
    private struct SupabaseToggleClipLikePayload: Encodable {
        let p_clip_id: String
        let p_reaction_id: String
    }
    
    private struct SupabaseToggleClipLikeResponse: Decodable {
        let liked: Bool
        let like_count: Int
    }
    
    private struct SupabaseAddCommentPayload: Encodable {
        let p_clip_id: String
        let p_content: String
        let p_parent_comment_id: String?
        let p_comment_id: String
    }
    
    private struct SupabaseClipCommentResponse: Decodable {
        let id: String
        let clip_id: String
        let user_id: String
        let parent_comment_id: String?
        let content: String
        let like_count: Int
        let reply_count: Int
        let created_at: String
        let updated_at: String
        let deleted_at: String?
        let display_name: String?
        let avatar_url: String?
    }
    
    private struct SupabaseToggleCommentLikePayload: Encodable {
        let p_comment_id: String
        let p_like_id: String
    }
    
    private struct SupabaseToggleCommentLikeResponse: Decodable {
        let liked: Bool
        let like_count: Int
    }
    
    private struct SupabaseDeleteCommentPayload: Encodable {
        let p_comment_id: String
    }
    
    private struct SupabaseCommentRow: Decodable {
        let id: String
        let clip_id: String
        let user_id: String
        let parent_comment_id: String?
        let content: String
        let like_count: Int
        let reply_count: Int
        let created_at: String
        let updated_at: String
        let deleted_at: String?
    }
    
    private struct SupabaseCommentLikeRow: Decodable {
        let id: String
        let comment_id: String
        let user_id: String
        let created_at: String?
    }
    
    private func syncCommentsFromSupabase(clipId: String, userId: String?, limit: Int, includeReplies: Bool) async -> [ClipComment]? {
        guard let client = supabase.client, supabase.isAuthenticated else { return nil }
        
        do {
            let rows: [SupabaseCommentRow] = try await client
                .from("clip_comments")
                .select("id, clip_id, user_id, parent_comment_id, content, like_count, reply_count, created_at, updated_at, deleted_at")
                .eq("clip_id", value: clipId)
                .is("parent_comment_id", value: nil)
                .is("deleted_at", value: nil)
                .order("created_at", ascending: includeReplies) // replies displayed oldest-first, comments newest-first
                .limit(limit)
                .execute()
                .value
            
            // Persist to SQLite
            let dictionariesUnsafe: [[String: Any]] = rows.map { row in
                var dict: [String: Any] = [
                    "id": row.id,
                    "clip_id": row.clip_id,
                    "user_id": row.user_id,
                    "content": row.content,
                    "like_count": row.like_count,
                    "reply_count": row.reply_count,
                    "created_at": row.created_at,
                    "updated_at": row.updated_at
                ]
                dict["parent_comment_id"] = row.parent_comment_id ?? NSNull()
                if let deleted = row.deleted_at { dict["deleted_at"] = deleted }
                return dict
            }
            // Wrap to avoid sending non-Sendable across actors
            let safe = SendableArrayOfDictionaries(raw: dictionariesUnsafe)
            try await sqlite.upsert(table: "clip_comments", rows: safe.raw)
            
            var likedSet = Set<String>()
            if let userId, !rows.isEmpty {
                let commentIds = rows.map { $0.id }
                do {
                    let likedRows: [SupabaseCommentLikeRow] = try await client
                        .from("clip_comment_likes")
                        .select("id, comment_id, user_id, created_at")
                        .eq("user_id", value: userId)
                        .in("comment_id", values: commentIds)
                        .execute()
                        .value
                    
                    let likeDictionariesUnsafe: [[String: Any]] = likedRows.map { like in
                        var dict: [String: Any] = [
                            "id": like.id,
                            "comment_id": like.comment_id,
                            "user_id": like.user_id
                        ]
                        if let created = like.created_at {
                            dict["created_at"] = created
                        }
                        return dict
                    }
                    let likeSafe = SendableArrayOfDictionaries(raw: likeDictionariesUnsafe)
                    try await sqlite.upsert(table: "clip_comment_likes", rows: likeSafe.raw)
                    likedSet = Set(likedRows.map { $0.comment_id })
                } catch {
                    print("⚠️ [ClipComment] Failed to sync liked comments from Supabase: \(error)")
                }
            }
            
            // Update local clip comment count to reflect remote truth
            try await setLocalClipCommentCount(clipId: clipId, count: rows.count)
            
            let comments = rows.compactMap { row -> ClipComment? in
                var comment = mapSupabaseCommentRow(row)
                comment.isLiked = likedSet.contains(comment.id)
                return comment
            }
            return comments
        } catch {
            print("⚠️ [ClipComment] Failed to sync comments from Supabase: \(error)")
            return nil
        }
    }
    
    private func syncRepliesFromSupabase(parentId: String, userId: String?, limit: Int) async -> [ClipComment]? {
        guard let client = supabase.client, supabase.isAuthenticated else { return nil }
        
        do {
            let rows: [SupabaseCommentRow] = try await client
                .from("clip_comments")
                .select("id, clip_id, user_id, parent_comment_id, content, like_count, reply_count, created_at, updated_at, deleted_at")
                .eq("parent_comment_id", value: parentId)
                .is("deleted_at", value: nil)
                .order("created_at", ascending: true)
                .limit(limit)
                .execute()
                .value
            
            let dictionariesUnsafe: [[String: Any]] = rows.map { row in
                var dict: [String: Any] = [
                    "id": row.id,
                    "clip_id": row.clip_id,
                    "user_id": row.user_id,
                    "content": row.content,
                    "like_count": row.like_count,
                    "reply_count": row.reply_count,
                    "created_at": row.created_at,
                    "updated_at": row.updated_at
                ]
                dict["parent_comment_id"] = row.parent_comment_id ?? NSNull()
                if let deleted = row.deleted_at { dict["deleted_at"] = deleted }
                return dict
            }
            let safe = SendableArrayOfDictionaries(raw: dictionariesUnsafe)
            try await sqlite.upsert(table: "clip_comments", rows: safe.raw)
            
            var likedSet = Set<String>()
            if let userId, !rows.isEmpty {
                let replyIds = rows.map { $0.id }
                do {
                    let likedRows: [SupabaseCommentLikeRow] = try await client
                        .from("clip_comment_likes")
                        .select("id, comment_id, user_id, created_at")
                        .eq("user_id", value: userId)
                        .in("comment_id", values: replyIds)
                        .execute()
                        .value
                    
                    let likeDictionariesUnsafe: [[String: Any]] = likedRows.map { like in
                        var dict: [String: Any] = [
                            "id": like.id,
                            "comment_id": like.comment_id,
                            "user_id": like.user_id
                        ]
                        if let created = like.created_at {
                            dict["created_at"] = created
                        }
                        return dict
                    }
                    let likeSafe = SendableArrayOfDictionaries(raw: likeDictionariesUnsafe)
                    try await sqlite.upsert(table: "clip_comment_likes", rows: likeSafe.raw)
                    likedSet = Set(likedRows.map { $0.comment_id })
                } catch {
                    print("⚠️ [ClipComment] Failed to sync liked replies from Supabase: \(error)")
                }
            }
            
            let replies = rows.compactMap { row -> ClipComment? in
                var comment = mapSupabaseCommentRow(row)
                comment.isLiked = likedSet.contains(comment.id)
                return comment
            }
            return replies
        } catch {
            print("⚠️ [ClipComment] Failed to sync replies from Supabase: \(error)")
            return nil
        }
    }
    
    private func mapSupabaseCommentRow(_ row: SupabaseCommentRow) -> ClipComment {
        let createdAt = isoFormatter.date(from: row.created_at) ?? Date()
        let updatedAt = isoFormatter.date(from: row.updated_at) ?? createdAt
        let deletedAt = row.deleted_at.flatMap { isoFormatter.date(from: $0) }
        
        return ClipComment(
            id: row.id,
            clipId: row.clip_id,
            userId: row.user_id,
            parentCommentId: row.parent_comment_id,
            content: row.content,
            likeCount: row.like_count,
            replyCount: row.reply_count,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
    
    private func supabaseToggleClipLike(clipId: String, reactionId: String) async -> SupabaseToggleClipLikeResponse? {
        guard let client = supabase.client, supabase.isAuthenticated else {
            return nil
        }
        
        do {
            let payload = SupabaseToggleClipLikePayload(p_clip_id: clipId, p_reaction_id: reactionId)
            let response: SupabaseToggleClipLikeResponse = try await client
                .rpc("clip_toggle_reaction", params: payload)
                .execute()
                .value
            return response
        } catch {
            print("⚠️ [ClipComment] Supabase clip like toggle failed: \(error)")
            return nil
        }
    }
    
    private func supabaseAddComment(clipId: String, content: String, parentId: String?, commentId: String) async -> ClipComment? {
        if commentRPCDisabled { return nil }
        guard let client = supabase.client, supabase.isAuthenticated else {
            return nil
        }
        
        do {
            let payload = SupabaseAddCommentPayload(
                p_clip_id: clipId,
                p_content: content,
                p_parent_comment_id: parentId,
                p_comment_id: commentId
            )
            let response: SupabaseClipCommentResponse = try await client
                .rpc("clip_add_comment", params: payload)
                .execute()
                .value
            
            let comment = try await persistSupabaseComment(response)
            return comment
        } catch {
            if let pgError = error as? PostgrestError, pgError.code == "42703" || pgError.message.contains("updated_at") {
                commentRPCDisabled = true
                print("⚠️ [ClipComment] Disabling comment RPC (server schema missing column): \(pgError.message)")
            }
            print("⚠️ [ClipComment] Supabase comment create failed: \(error)")
            return nil
        }
    }
    
    private func supabaseToggleCommentLike(commentId: String, likeId: String) async -> SupabaseToggleCommentLikeResponse? {
        guard let client = supabase.client, supabase.isAuthenticated else {
            return nil
        }
        
        do {
            let payload = SupabaseToggleCommentLikePayload(p_comment_id: commentId, p_like_id: likeId)
            let response: SupabaseToggleCommentLikeResponse = try await client
                .rpc("clip_toggle_comment_like", params: payload)
                .execute()
                .value
            return response
        } catch {
            print("⚠️ [ClipComment] Supabase comment like toggle failed: \(error)")
            return nil
        }
    }
    
    private func supabaseDeleteComment(commentId: String) async -> Bool {
        guard let client = supabase.client, supabase.isAuthenticated else {
            return false
        }
        
        do {
            let payload = SupabaseDeleteCommentPayload(p_comment_id: commentId)
            _ = try await client
                .rpc("clip_delete_comment", params: payload)
                .execute()
            return true
        } catch {
            print("⚠️ [ClipComment] Supabase comment delete failed: \(error)")
            return false
        }
    }
    
    private func setClipLiked(clipId: String, userId: String, liked: Bool, reactionId: String, markSynced: Bool = false) async throws -> Bool {
        let wasLiked = try await hasUserLikedClip(clipId: clipId, userId: userId)
        
        if liked {
            if wasLiked { return true }
            
            let now = isoFormatter.string(from: Date())
            let success = sqlite.execute("""
                INSERT OR REPLACE INTO clip_reactions (id, clip_id, user_id, reaction_type, created_at, updated_at, synced_at)
                VALUES (?, ?, ?, 'like', ?, ?, ?)
            """, parameters: [reactionId, clipId, userId, now, now, markSynced ? now : NSNull()])
            
            guard success else {
                throw NSError(domain: "ClipCommentService", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to add clip like"
                ])
            }
            adjustLocalClipLikeCount(clipId: clipId, delta: 1)
            return true
        } else {
            if !wasLiked { return false }
            
            let success = sqlite.execute("""
                DELETE FROM clip_reactions
                WHERE clip_id = ? AND user_id = ? AND reaction_type = 'like'
            """, parameters: [clipId, userId])
            
            guard success else {
                throw NSError(domain: "ClipCommentService", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to remove clip like"
                ])
            }
            adjustLocalClipLikeCount(clipId: clipId, delta: -1)
            return false
        }
    }
    
    private func setCommentLiked(
        commentId: String,
        userId: String,
        liked: Bool,
        likeId: String,
        remoteLikeCount: Int?,
        markSynced: Bool = false
    ) async throws -> Bool {
        let wasLiked = try await hasUserLikedComment(commentId: commentId, userId: userId)
        
        if liked && !wasLiked {
            let now = isoFormatter.string(from: Date())
            let success = sqlite.execute("""
                INSERT OR REPLACE INTO clip_comment_likes (id, comment_id, user_id, created_at, synced_at)
                VALUES (?, ?, ?, ?, ?)
            """, parameters: [likeId, commentId, userId, now, markSynced ? now : NSNull()])
            
            guard success else {
                throw NSError(domain: "ClipCommentService", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to add comment like"
                ])
            }
        } else if !liked && wasLiked {
            let success = sqlite.execute("""
                DELETE FROM clip_comment_likes
                WHERE comment_id = ? AND user_id = ?
            """, parameters: [commentId, userId])
            
            guard success else {
                throw NSError(domain: "ClipCommentService", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to remove comment like"
                ])
            }
        }
        
        if let remoteLikeCount {
            let success = sqlite.execute("""
                UPDATE clip_comments
                SET like_count = ?, synced_at = ?
                WHERE id = ?
            """, parameters: [remoteLikeCount, markSynced ? isoFormatter.string(from: Date()) : NSNull(), commentId])
            
            if !success {
                print("⚠️ [ClipComment] Failed to sync like_count for comment \(commentId)")
            }
        } else if liked && !wasLiked {
            let success = sqlite.execute("""
                UPDATE clip_comments
                SET like_count = like_count + 1, synced_at = NULL
                WHERE id = ?
            """, parameters: [commentId])
            if !success {
                print("⚠️ [ClipComment] Failed to increment like count for comment \(commentId)")
            }
        } else if !liked && wasLiked {
            let success = sqlite.execute("""
                UPDATE clip_comments
                SET like_count = MAX(0, like_count - 1), synced_at = NULL
                WHERE id = ?
            """, parameters: [commentId])
            if !success {
                print("⚠️ [ClipComment] Failed to decrement like count for comment \(commentId)")
            }
        }
        
        return liked
    }
    
    private func persistSupabaseComment(_ response: SupabaseClipCommentResponse) async throws -> ClipComment {
        var row: [String: Any] = [
            "id": response.id,
            "clip_id": response.clip_id,
            "user_id": response.user_id,
            "content": response.content,
            "like_count": response.like_count,
            "reply_count": response.reply_count,
            "created_at": response.created_at,
            "updated_at": response.updated_at
        ]
        
        row["parent_comment_id"] = response.parent_comment_id ?? NSNull()
        
        if let deletedAt = response.deleted_at {
            row["deleted_at"] = deletedAt
        }
        
        // Wrap to avoid sending non-Sendable across actors
        let safe = SendableArrayOfDictionaries(raw: [row])
        try await sqlite.upsert(table: "clip_comments", rows: safe.raw)
        var comment = mapSupabaseComment(response)
        
        // Backfill denormalized user info if Supabase response didn't include it
        if comment.userDisplayName == nil {
            comment.userDisplayName = AuthService.shared.currentUser?.displayName ?? "User"
        }
        if comment.userAvatarURL == nil {
            comment.userAvatarURL = AuthService.shared.currentUser?.avatarURL
        }
        
        return comment
    }
    
    private func mapSupabaseComment(_ response: SupabaseClipCommentResponse) -> ClipComment {
        let createdAt = isoFormatter.date(from: response.created_at) ?? Date()
        let updatedAt = isoFormatter.date(from: response.updated_at) ?? createdAt
        let deletedAt = response.deleted_at.flatMap { isoFormatter.date(from: $0) }
        
        var comment = ClipComment(
            id: response.id,
            clipId: response.clip_id,
            userId: response.user_id,
            parentCommentId: response.parent_comment_id,
            content: response.content,
            likeCount: response.like_count,
            replyCount: response.reply_count,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
        
        comment.userDisplayName = response.display_name
        comment.userAvatarURL = response.avatar_url
        
        return comment
    }
    
    private func adjustLocalClipCommentCount(clipId: String, delta: Int) {
        _ = sqlite.execute("""
            UPDATE clips
            SET comments = MAX(0, comments + ?)
            WHERE clip_id = ?
        """, parameters: [delta, clipId])
    }
    
    private func setLocalClipCommentCount(clipId: String, count: Int) async throws {
        _ = try await sqlite.queryRaw("""
            UPDATE clips
            SET comments = ?
            WHERE clip_id = ?
        """, parameters: [count, clipId])
    }
    
    private func adjustLocalClipLikeCount(clipId: String, delta: Int) {
        _ = sqlite.execute("""
            UPDATE clips
            SET likes = MAX(0, likes + ?)
            WHERE clip_id = ?
        """, parameters: [delta, clipId])
    }
    
    private func setLocalClipLikeCount(clipId: String, count: Int) async {
        _ = sqlite.execute("""
            UPDATE clips
            SET likes = ?
            WHERE clip_id = ?
        """, parameters: [count, clipId])
    }
    
    private func existingClipReactionId(clipId: String, userId: String) async throws -> String? {
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT id FROM clip_reactions
            WHERE clip_id = ? AND user_id = ? AND reaction_type = 'like'
            LIMIT 1
        """, parameters: [clipId, userId])
        return rows.first?["id"] as? String
    }
    
    private func existingCommentLikeId(commentId: String, userId: String) async throws -> String? {
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT id FROM clip_comment_likes
            WHERE comment_id = ? AND user_id = ?
            LIMIT 1
        """, parameters: [commentId, userId])
        return rows.first?["id"] as? String
    }
    
    private func loadComment(commentId: String) async throws -> ClipComment {
        let rows: [[String: Any]] = try await sqlite.queryRaw("""
            SELECT 
                c.id, c.clip_id, c.user_id, c.parent_comment_id, c.content,
                c.like_count, c.reply_count, c.created_at, c.updated_at,
                p.display_name, p.avatar_url
            FROM clip_comments c
            LEFT JOIN profiles p ON c.user_id = p.id
            WHERE c.id = ?
        """, parameters: [commentId])
        
        guard let comment = rows.first, let clipComment = ClipComment.from(dictionary: comment) else {
            throw NSError(domain: "ClipCommentService", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to fetch created comment"
            ])
        }
        return clipComment
    }
    
    private func queueOutbox(userId: String, tableName: String, operation: String, recordId: String, payload: [String: Any]) async {
        do {
            try await SyncWorker.shared.queueOperation(
                userId: userId,
                tableName: tableName,
                operationType: operation,
                recordId: recordId,
                payload: payload
            )
        } catch {
            print("⚠️ [ClipComment] Failed to enqueue outbox for \(tableName): \(error)")
        }
    }
    
    private func markSynced(table: String, recordId: String) {
        let now = isoFormatter.string(from: Date())
        let sql = "UPDATE \(table) SET synced_at = ? WHERE id = ?"
        _ = sqlite.execute(sql, parameters: [now, recordId])
    }
    
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
                let now = isoFormatter.string(from: Date())
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
        let now = isoFormatter.string(from: Date())
        
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
