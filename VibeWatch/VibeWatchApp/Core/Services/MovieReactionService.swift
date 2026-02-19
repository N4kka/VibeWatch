import Foundation

@MainActor
class MovieReactionService: ObservableObject {
    static let shared = MovieReactionService()
    
    private let db = SQLiteService.shared
    private let supabase = SupabaseService.shared
    
    // Cache for reaction counts to avoid repeated DB queries
    private var countsCache: [String: MovieReactionCounts] = [:]
    
    private init() {}
    
    // MARK: - Get Reaction Counts
    
    /// Fetch reaction counts for a movie/TV show
    func getReactionCounts(mediaId: Int, mediaType: MediaType) async throws -> MovieReactionCounts {
        let cacheKey = "\(mediaType.rawValue)_\(mediaId)"
        
        // Return cached if available
        if let cached = countsCache[cacheKey] {
            return cached
        }
        
        // Try Supabase first if authenticated
        if supabase.currentUser != nil {
            do {
                let counts = try await fetchCountsFromSupabase(mediaId: mediaId, mediaType: mediaType)
                countsCache[cacheKey] = counts
                return counts
            } catch {
                Logger.warning("[MovieReaction] Failed to fetch from Supabase: \(error)")
                // Fall through to SQLite
            }
        }
        
        // Fetch from local SQLite
        let counts = try await fetchCountsFromSQLite(mediaId: mediaId, mediaType: mediaType)
        countsCache[cacheKey] = counts
        return counts
    }
    
    // MARK: - Get User Reaction
    
    /// Get the current user's reaction for a movie/TV show
    func getUserReaction(mediaId: Int, mediaType: MediaType, userId: String) async throws -> ReactionType? {
        // Try SQLite first (faster)
        let query = """
            SELECT reaction_type FROM movie_reactions
            WHERE user_id = ? AND media_id = ? AND media_type = ?
            LIMIT 1
        """
        
        let rows: [[String: Any]] = try await db.queryRaw(query, parameters: [userId, mediaId, mediaType.rawValue])
        
        if let row = rows.first,
           let reactionTypeStr = row["reaction_type"] as? String,
           let reactionType = ReactionType(rawValue: reactionTypeStr) {
            return reactionType
        }
        
        return nil
    }
    
    // MARK: - Update Reaction Counts
    
    /// Update reaction counts when list membership changes
    /// This is called by the existing Like/Dislike buttons that manage lists
    func updateReactionCounts(mediaId: Int, mediaType: MediaType, oldReaction: ReactionType?, newReaction: ReactionType?) async throws {
        // Update counts in SQLite
        try await updateCountsInSQLite(mediaId: mediaId, mediaType: mediaType, newReaction: newReaction, oldReaction: oldReaction)
        
        // Clear cache
        let cacheKey = "\(mediaType.rawValue)_\(mediaId)"
        countsCache.removeValue(forKey: cacheKey)
        
        // Sync to Supabase if authenticated
        if supabase.currentUser != nil {
            Task {
                do {
                    try await syncCountsToSupabase(mediaId: mediaId, mediaType: mediaType)
                    Logger.debug("[MovieReaction] Synced counts to Supabase")
                } catch {
                    Logger.warning("[MovieReaction] Failed to sync counts to Supabase: \(error)")
                }
            }
        }
        
        // Analytics
        if let new = newReaction {
            AnalyticsService.shared.logEvent(
                "reaction_added",
                parameters: [
                    "media_id": mediaId,
                    "media_type": mediaType.rawValue,
                    "reaction_type": new.rawValue
                ]
            )
        } else if let old = oldReaction {
            AnalyticsService.shared.logEvent(
                "reaction_removed",
                parameters: [
                    "media_id": mediaId,
                    "media_type": mediaType.rawValue,
                    "reaction_type": old.rawValue
                ]
            )
        }
        
        Logger.debug("[MovieReaction] Updated counts: \(oldReaction?.rawValue ?? "none") → \(newReaction?.rawValue ?? "none") for \(mediaType.rawValue) \(mediaId)")
    }
    
    // MARK: - Toggle Reaction
    
    /// Toggle like/dislike for a movie/TV show
    func toggleReaction(
        mediaId: Int,
        mediaType: MediaType,
        reaction: ReactionType,
        userId: String,
        context: AnalyticsContext? = nil
    ) async throws {
        // Get current reaction
        let currentReaction = try await getUserReaction(mediaId: mediaId, mediaType: mediaType, userId: userId)
        
        if currentReaction == reaction {
            // User is removing their reaction
            try await removeReaction(mediaId: mediaId, mediaType: mediaType, userId: userId, reaction: reaction)
        } else {
            // User is adding or changing reaction
            try await setReaction(mediaId: mediaId, mediaType: mediaType, userId: userId, reaction: reaction, previousReaction: currentReaction)
        }
        
        // Clear cache to force refresh
        let cacheKey = "\(mediaType.rawValue)_\(mediaId)"
        countsCache.removeValue(forKey: cacheKey)
        
        // Analytics
        AnalyticsService.shared.logEventWithContext(
            currentReaction == reaction ? "reaction_removed" : "reaction_added",
            parameters: [
                "media_id": mediaId,
                "media_type": mediaType.rawValue,
                "reaction_type": reaction.rawValue
            ],
            context: context
        )
    }
    
    // MARK: - Private Helpers
    
    private func setReaction(mediaId: Int, mediaType: MediaType, userId: String, reaction: ReactionType, previousReaction: ReactionType?) async throws {
        let reactionId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        
        // 1. Insert or update reaction in SQLite
        let upsertQuery = """
            INSERT INTO movie_reactions (id, user_id, media_id, media_type, reaction_type, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, media_id, media_type)
            DO UPDATE SET reaction_type = ?, updated_at = ?
        """
        
        _ = db.execute(upsertQuery, parameters: [
            reactionId, userId, mediaId, mediaType.rawValue, reaction.rawValue, now, now,
            reaction.rawValue, now
        ])
        
        // 2. Update counts in SQLite
        try await updateCountsInSQLite(mediaId: mediaId, mediaType: mediaType, newReaction: reaction, oldReaction: previousReaction)
        
        // 3. Sync to Supabase if authenticated
        if supabase.currentUser != nil {
            Task {
                do {
                    try await syncReactionToSupabase(mediaId: mediaId, mediaType: mediaType, userId: userId, reaction: reaction)
                    Logger.debug("[MovieReaction] Synced reaction to Supabase")
                } catch {
                    Logger.warning("[MovieReaction] Failed to sync to Supabase: \(error)")
                    // Don't throw - local save succeeded
                }
            }
        }
        
        Logger.debug("[MovieReaction] Set \(reaction.rawValue) for \(mediaType.rawValue) \(mediaId)")
    }
    
    private func removeReaction(mediaId: Int, mediaType: MediaType, userId: String, reaction: ReactionType) async throws {
        // 1. Delete from SQLite
        let deleteQuery = """
            DELETE FROM movie_reactions
            WHERE user_id = ? AND media_id = ? AND media_type = ?
        """
        
        _ = db.execute(deleteQuery, parameters: [userId, mediaId, mediaType.rawValue])
        
        // 2. Update counts
        try await updateCountsInSQLite(mediaId: mediaId, mediaType: mediaType, newReaction: nil, oldReaction: reaction)
        
        // 3. Sync to Supabase
        if supabase.currentUser != nil {
            Task {
                do {
                    try await deleteReactionFromSupabase(mediaId: mediaId, mediaType: mediaType, userId: userId)
                    Logger.debug("[MovieReaction] Deleted reaction from Supabase")
                } catch {
                    Logger.warning("[MovieReaction] Failed to delete from Supabase: \(error)")
                }
            }
        }
        
        Logger.debug("[MovieReaction] Removed \(reaction.rawValue) for \(mediaType.rawValue) \(mediaId)")
    }
    
    // MARK: - SQLite Helpers
    
    private func fetchCountsFromSQLite(mediaId: Int, mediaType: MediaType) async throws -> MovieReactionCounts {
        let query = """
            SELECT like_count, dislike_count, updated_at
            FROM movie_reaction_counts
            WHERE media_id = ? AND media_type = ?
        """
        
        let rows: [[String: Any]] = try await db.queryRaw(query, parameters: [mediaId, mediaType.rawValue])
        
        if let row = rows.first {
            let likeCount = row["like_count"] as? Int ?? 0
            let dislikeCount = row["dislike_count"] as? Int ?? 0
            let updatedAtStr = row["updated_at"] as? String ?? ""
            let updatedAt = ISO8601DateFormatter().date(from: updatedAtStr) ?? Date()
            
            return MovieReactionCounts(
                mediaId: mediaId,
                mediaType: mediaType,
                likeCount: likeCount,
                dislikeCount: dislikeCount,
                updatedAt: updatedAt
            )
        }
        
        // No counts yet, return zeros
        return MovieReactionCounts(mediaId: mediaId, mediaType: mediaType)
    }
    
    private func updateCountsInSQLite(mediaId: Int, mediaType: MediaType, newReaction: ReactionType?, oldReaction: ReactionType?) async throws {
        // Calculate delta
        var likeDelta = 0
        var dislikeDelta = 0
        
        if let old = oldReaction {
            // Removing old reaction
            if old == .like {
                likeDelta -= 1
            } else {
                dislikeDelta -= 1
            }
        }
        
        if let new = newReaction {
            // Adding new reaction
            if new == .like {
                likeDelta += 1
            } else {
                dislikeDelta += 1
            }
        }
        
        let now = ISO8601DateFormatter().string(from: Date())
        
        // Upsert counts
        let upsertQuery = """
            INSERT INTO movie_reaction_counts (media_id, media_type, like_count, dislike_count, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(media_id, media_type)
            DO UPDATE SET 
                like_count = MAX(0, like_count + ?),
                dislike_count = MAX(0, dislike_count + ?),
                updated_at = ?
        """
        
        _ = db.execute(upsertQuery, parameters: [
            mediaId, mediaType.rawValue, max(0, likeDelta), max(0, dislikeDelta), now,
            likeDelta, dislikeDelta, now
        ])
    }
    
    // MARK: - Supabase Helpers
    
    private func fetchCountsFromSupabase(mediaId: Int, mediaType: MediaType) async throws -> MovieReactionCounts {
        // Supabase endpoint pending - fallback to SQLite for now
        return try await fetchCountsFromSQLite(mediaId: mediaId, mediaType: mediaType)
    }
    
    private func syncReactionToSupabase(mediaId: Int, mediaType: MediaType, userId: String, reaction: ReactionType) async throws {
        guard let client = supabase.client else {
            Logger.warning("[MovieReaction] No Supabase client - queueing for later sync")
            await queueReactionForSync(mediaId: mediaId, mediaType: mediaType, userId: userId, reaction: reaction)
            return
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let reactionId = "\(userId)_\(mediaId)_\(mediaType.rawValue)"

        struct ReactionRecord: Encodable {
            let id: String
            let user_id: String
            let media_id: Int
            let media_type: String
            let reaction_type: String
            let created_at: String
            let updated_at: String
        }

        let record = ReactionRecord(
            id: reactionId,
            user_id: userId,
            media_id: mediaId,
            media_type: mediaType.rawValue,
            reaction_type: reaction.rawValue,
            created_at: now,
            updated_at: now
        )

        do {
            try await client.from("movie_reactions")
                .upsert(record)
                .execute()

            Logger.debug("[MovieReaction] Synced reaction to Supabase")
        } catch {
            Logger.warning("[MovieReaction] Failed to sync reaction: \(error)")
            await queueReactionForSync(mediaId: mediaId, mediaType: mediaType, userId: userId, reaction: reaction)
            throw error
        }
    }
    
    private func deleteReactionFromSupabase(mediaId: Int, mediaType: MediaType, userId: String) async throws {
        guard let client = supabase.client else {
            Logger.warning("[MovieReaction] No Supabase client for deletion")
            return
        }

        do {
            try await client.from("movie_reactions")
                .delete()
                .eq("user_id", value: userId)
                .eq("media_id", value: mediaId)
                .eq("media_type", value: mediaType.rawValue)
                .execute()

            Logger.debug("[MovieReaction] Deleted reaction from Supabase")
        } catch {
            Logger.warning("[MovieReaction] Failed to delete from Supabase: \(error)")
            throw error
        }
    }
    
    private func syncCountsToSupabase(mediaId: Int, mediaType: MediaType) async throws {
        guard let client = supabase.client else { return }

        // Get current local counts
        let counts = try await fetchCountsFromSQLite(mediaId: mediaId, mediaType: mediaType)
        let now = ISO8601DateFormatter().string(from: Date())

        struct CountsRecord: Encodable {
            let media_id: Int
            let media_type: String
            let like_count: Int
            let dislike_count: Int
            let updated_at: String
        }

        let record = CountsRecord(
            media_id: mediaId,
            media_type: mediaType.rawValue,
            like_count: counts.likeCount,
            dislike_count: counts.dislikeCount,
            updated_at: now
        )

        do {
            try await client.from("movie_reaction_counts")
                .upsert(record)
                .execute()

            Logger.debug("[MovieReaction] Synced counts to Supabase: \(counts.likeCount) likes, \(counts.dislikeCount) dislikes")
        } catch {
            Logger.warning("[MovieReaction] Failed to sync counts: \(error)")
        }
    }
    
    private func queueReactionForSync(mediaId: Int, mediaType: MediaType, userId: String, reaction: ReactionType) async {
        let reactionId = "\(userId)_\(mediaId)_\(mediaType.rawValue)"
        let now = ISO8601DateFormatter().string(from: Date())

        let payload: [String: Any] = [
            "id": reactionId,
            "user_id": userId,
            "media_id": mediaId,
            "media_type": mediaType.rawValue,
            "reaction_type": reaction.rawValue,
            "created_at": now,
            "updated_at": now
        ]

        do {
            try await SyncEngine.shared.queueOperation(
                table: "movie_reactions",
                operationType: "UPSERT",
                recordId: reactionId,
                payload: payload,
                dependsOn: nil
            )
            Logger.debug("[MovieReaction] Queued reaction for sync")
        } catch {
            Logger.error("[MovieReaction] Failed to queue reaction: \(error)")
        }
    }

    // MARK: - Cache Management

    func clearCache() {
        countsCache.removeAll()
    }
    
    func clearCache(for mediaId: Int, mediaType: MediaType) {
        let cacheKey = "\(mediaType.rawValue)_\(mediaId)"
        countsCache.removeValue(forKey: cacheKey)
    }
}
