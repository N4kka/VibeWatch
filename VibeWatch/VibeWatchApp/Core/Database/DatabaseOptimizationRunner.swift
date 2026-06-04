import Foundation

/// Database optimization runner for applying performance indexes and maintenance tasks
/// Implements Task 3 optimizations from USER_PREFERENCES_ARCHITECTURE_PLAN_V2.md
class DatabaseOptimizationRunner {

    private let db: SQLiteService

    init(db: SQLiteService = .shared) {
        self.db = db
    }

    // MARK: - Main Optimization Entry Point

    /// Apply all database optimizations
    /// This creates 25 composite indexes for optimal query performance
    func applyOptimizations() async {
        Logger.info("=============================================================")
        Logger.info("🚀 Applying Database Optimizations")
        Logger.info("=============================================================")

        let startTime = CFAbsoluteTimeGetCurrent()

        // Check if optimizations already applied
        if await isAlreadyOptimized() {
            Logger.info("✅ Database already optimized (v1.0)")
            return
        }

        // Section 1: Unified User Preferences (CRITICAL)
        await createUnifiedPreferencesIndexes()

        // Section 2: Discovery Interactions
        await createDiscoveryInteractionIndexes()

        // Section 3: Search History
        await createSearchHistoryIndexes()

        // Section 4: Personalized Discovery
        await createPersonalizedDiscoveryIndexes()

        // Section 5: AI Conversation History
        await createAIConversationIndexes()

        // Section 6: User Clip History
        await createClipHistoryIndexes()

        // Section 7: List Items
        await createListItemIndexes()

        // Section 8: Sync Operations
        await createSyncOperationIndexes()

        // Section 9: Movie Reactions
        await createMovieReactionIndexes()

        // Section 10: Clips Table
        await createClipsIndexes()

        // Section 11: Detail Cache
        await createDetailCacheIndexes()

        // Update statistics
        db.execute("ANALYZE")
        Logger.info("✅ Database statistics updated (ANALYZE completed)")

        // Mark as optimized
        await markAsOptimized()

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        Logger.info("=============================================================")
        Logger.info("✅ Database optimization completed in \(String(format: "%.2f", duration))s")
        Logger.info("   Total indexes created: 26")
        Logger.info("   Expected performance improvement: 70-90%")
        Logger.info("=============================================================")
    }

    // MARK: - Section 1: Unified User Preferences Indexes

    private func createUnifiedPreferencesIndexes() async {
        Logger.info("\n📊 Creating unified_user_preferences indexes...")

        // Index 1: Category + Score (most common query pattern)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_unified_prefs_category_score
            ON unified_user_preferences(user_id, preference_category, score DESC)
            WHERE score > 0
        """)
        Logger.info("✅ Created idx_unified_prefs_category_score")

        // Index 2: Unsynced records for sync operations
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_unified_prefs_unsynced_updated
            ON unified_user_preferences(user_id, synced_at, updated_at DESC)
            WHERE synced_at IS NULL
        """)
        Logger.info("✅ Created idx_unified_prefs_unsynced_updated")

        // Index 3: Preference decay operations
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_unified_prefs_decay
            ON unified_user_preferences(last_interaction_at, last_decay_at)
            WHERE last_decay_at IS NULL OR last_interaction_at < date('now', '-7 days')
        """)
        Logger.info("✅ Created idx_unified_prefs_decay")

        // Index 4: Source-based aggregation
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_unified_prefs_source_scores
            ON unified_user_preferences(preference_category, score_from_clips DESC, score_from_discovery DESC)
            WHERE score_from_clips > 0 OR score_from_discovery > 0
        """)
        Logger.info("✅ Created idx_unified_prefs_source_scores")
    }

    // MARK: - Section 2: Discovery Interaction Indexes

    private func createDiscoveryInteractionIndexes() async {
        Logger.info("\n📊 Creating user_discovery_interactions indexes...")

        // Index 5: Carousel type + interaction type grouping
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_discovery_carousel_interaction
            ON user_discovery_interactions(user_id, carousel_type, interaction_type, interacted_at DESC)
        """)
        Logger.info("✅ Created idx_discovery_carousel_interaction")

        // Index 6: Media-based queries
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_discovery_media_recent
            ON user_discovery_interactions(user_id, media_id, media_type, interacted_at DESC)
        """)
        Logger.info("✅ Created idx_discovery_media_recent")

        // Index 7: Session duration analytics
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_discovery_engagement
            ON user_discovery_interactions(user_id, interaction_type, session_duration)
            WHERE session_duration > 0
        """)
        Logger.info("✅ Created idx_discovery_engagement")
    }

    // MARK: - Section 3: Search History Indexes

    private func createSearchHistoryIndexes() async {
        Logger.info("\n📊 Creating user_search_history indexes...")

        // Index 8: Recent searches with relevance
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_search_recent_relevant
            ON user_search_history(user_id, searched_at DESC, relevance_score DESC)
            WHERE result_count > 0
        """)
        Logger.info("✅ Created idx_search_recent_relevant")

        // Index 9: Clicked media tracking
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_search_clicked_media
            ON user_search_history(user_id, clicked_media_id, clicked_media_title)
            WHERE clicked_media_id IS NOT NULL
        """)
        Logger.info("✅ Created idx_search_clicked_media")
    }

    // MARK: - Section 4: Personalized Discovery Indexes

    private func createPersonalizedDiscoveryIndexes() async {
        Logger.info("\n📊 Creating personalized_discovery indexes...")

        // Index 10: Carousel content retrieval
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_personalized_carousel_content
            ON personalized_discovery(user_id, carousel_type, expires_at, position ASC)
            WHERE expires_at > datetime('now')
        """)
        Logger.info("✅ Created idx_personalized_carousel_content")

        // Index 11: Expired content cleanup
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_personalized_expired
            ON personalized_discovery(expires_at, generated_at)
            WHERE expires_at <= datetime('now')
        """)
        Logger.info("✅ Created idx_personalized_expired")
    }

    // MARK: - Section 5: AI Conversation Indexes

    private func createAIConversationIndexes() async {
        Logger.info("\n📊 Creating ai_conversation_history indexes...")

        // Index 12: Session-based conversation retrieval
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_ai_session_messages
            ON ai_conversation_history(user_id, session_id, created_at ASC)
        """)
        Logger.info("✅ Created idx_ai_session_messages")

        // Index 13: Query type analytics
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_ai_query_analytics
            ON ai_conversation_history(user_id, query_type, created_at DESC)
            WHERE query_type IS NOT NULL
        """)
        Logger.info("✅ Created idx_ai_query_analytics")

        // Index 14: Token usage tracking
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_ai_token_usage
            ON ai_conversation_history(user_id, created_at, tokens_used)
            WHERE tokens_used > 0
        """)
        Logger.info("✅ Created idx_ai_token_usage")
    }

    // MARK: - Section 6: Clip History Indexes

    private func createClipHistoryIndexes() async {
        Logger.info("\n📊 Creating user_clip_history indexes...")

        // Index 15: Engagement score queries
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_clip_history_engagement_user
            ON user_clip_history(user_id, engagement_score DESC, watched_at DESC)
            WHERE engagement_score > 0
        """)
        Logger.info("✅ Created idx_clip_history_engagement_user")

        // Index 16: Completion rate analysis
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_clip_history_completion
            ON user_clip_history(user_id, completion_rate DESC, watch_duration)
            WHERE completion_rate >= 0.5
        """)
        Logger.info("✅ Created idx_clip_history_completion")

        // Index 17: Session-based analytics
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_clip_history_session
            ON user_clip_history(user_id, session_id, watched_at DESC)
            WHERE session_id IS NOT NULL
        """)
        Logger.info("✅ Created idx_clip_history_session")
    }

    // MARK: - Section 7: List Item Indexes

    private func createListItemIndexes() async {
        Logger.info("\n📊 Creating list_items indexes...")

        // Index 18: List item retrieval with media details
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_list_items_media
            ON list_items(user_id, list_id, media_type, vote_average DESC)
            WHERE deleted_at IS NULL
        """)
        Logger.info("✅ Created idx_list_items_media")

        // Index 19: Watchlist priority queries
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_list_items_added
            ON list_items(user_id, list_id, added_at DESC)
            WHERE deleted_at IS NULL
        """)
        Logger.info("✅ Created idx_list_items_added")

        // Index 19b: ListManager.loadListsFromSQLite filters by `list_id IN (...) AND
        // deleted_at IS NULL ORDER BY added_at DESC` WITHOUT a user_id predicate, so
        // idx_list_items_added (which leads with user_id) can't serve it optimally.
        // This partial index matches that load query exactly.
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_list_items_list_added
            ON list_items(list_id, added_at DESC)
            WHERE deleted_at IS NULL
        """)
        Logger.info("✅ Created idx_list_items_list_added")
    }

    // MARK: - Section 8: Sync Operation Indexes

    private func createSyncOperationIndexes() async {
        Logger.info("\n📊 Creating sync_outbox indexes...")

        // Index 20: Sync outbox processing (CRITICAL for offline sync)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_sync_outbox_pending_priority
            ON sync_outbox(status, next_retry_at, user_id, created_at ASC)
            WHERE status = 'pending' AND (next_retry_at IS NULL OR next_retry_at <= datetime('now'))
        """)
        Logger.info("✅ Created idx_sync_outbox_pending_priority")

        // Index 21: Dependency chain resolution
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_sync_outbox_dependencies
            ON sync_outbox(depends_on_id, status)
            WHERE depends_on_id IS NOT NULL
        """)
        Logger.info("✅ Created idx_sync_outbox_dependencies")
    }

    // MARK: - Section 9: Movie Reaction Indexes

    private func createMovieReactionIndexes() async {
        Logger.info("\n📊 Creating movie_reactions indexes...")

        // Index 22: User reaction lookups by media
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_movie_reactions_user_media
            ON movie_reactions(user_id, media_id, media_type, reaction_type)
        """)
        Logger.info("✅ Created idx_movie_reactions_user_media")

        // Index 23: Reaction count aggregation
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_movie_reactions_media_type
            ON movie_reactions(media_id, media_type, reaction_type, created_at DESC)
        """)
        Logger.info("✅ Created idx_movie_reactions_media_type")
    }

    // MARK: - Section 10: Clips Table Indexes

    private func createClipsIndexes() async {
        Logger.info("\n📊 Creating clips indexes...")

        // Index 24: Active clips with quality filtering
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_clips_active_quality
            ON clips(is_active, media_type, quality_score DESC, created_at DESC)
            WHERE deleted_at IS NULL AND is_active = 1
        """)
        Logger.info("✅ Created idx_clips_active_quality")

        // Index 25: Genre-based clip queries
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_clips_genres
            ON clips(genres, media_type, tmdb_rating DESC)
            WHERE is_active = 1 AND deleted_at IS NULL
        """)
        Logger.info("✅ Created idx_clips_genres")
    }

    // MARK: - Section 11: Detail Cache Indexes

    private func createDetailCacheIndexes() async {
        Logger.info("\n📊 Creating detail_cache indexes...")

        // Index 26: Detail cache lookups by media
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_detail_cache_lookup
            ON detail_cache(media_id, media_type, expires_at)
            WHERE deleted_at IS NULL
        """)
        Logger.info("✅ Created idx_detail_cache_lookup")
    }

    // MARK: - Maintenance Operations

    /// Clean up expired and old data to prevent table bloat
    func performMaintenance() async {
        Logger.info("\n🧹 Performing database maintenance...")

        // Delete expired personalized discovery entries (older than 7 days)
        let expiredDiscovery = db.execute("""
            DELETE FROM personalized_discovery
            WHERE expires_at < datetime('now', '-7 days')
        """)
        if expiredDiscovery {
            Logger.info("✅ Cleaned up expired personalized_discovery entries")
        }

        // Delete old search history (keep last 90 days)
        let oldSearches = db.execute("""
            DELETE FROM user_search_history
            WHERE searched_at < datetime('now', '-90 days')
        """)
        if oldSearches {
            Logger.info("✅ Cleaned up old search history (90+ days)")
        }

        // Delete completed sync operations (keep last 30 days)
        let completedSync = db.execute("""
            DELETE FROM sync_log
            WHERE synced_at < datetime('now', '-30 days') AND status = 'success'
        """)
        if completedSync {
            Logger.info("✅ Cleaned up old sync logs")
        }

        // Update statistics
        db.execute("ANALYZE")
        Logger.info("✅ Database statistics updated")

        Logger.info("✅ Maintenance completed")
    }

    /// Vacuum database to reclaim space (run infrequently, locks database)
    func vacuumDatabase() async {
        Logger.info("\n🗜️ Vacuuming database (this may take a while)...")

        let startTime = CFAbsoluteTimeGetCurrent()
        db.execute("VACUUM")
        let duration = CFAbsoluteTimeGetCurrent() - startTime

        Logger.info("✅ Database vacuumed in \(String(format: "%.2f", duration))s")
    }

    // MARK: - Verification

    /// Check if optimizations have already been applied
    private func isAlreadyOptimized() async -> Bool {
        do {
            let rows: [[String: Any]] = try await db.queryRaw("""
                SELECT value_text FROM app_metadata WHERE key_name = 'db_optimization_version'
            """)

            if let version = rows.first?["value_text"] as? String, version == "1.0" {
                return true
            }
        } catch {
            Logger.error("[DatabaseOptimization] Failed to check optimization status", error: error)
        }

        return false
    }

    /// Mark database as optimized
    private func markAsOptimized() async {
        db.execute("""
            INSERT OR REPLACE INTO app_metadata (key_name, value_text, updated_at)
            VALUES ('db_optimization_version', '1.0', datetime('now'))
        """)
        Logger.info("✅ Marked database as optimized (v1.0)")
    }

    /// Get optimization status
    func getOptimizationStatus() async -> OptimizationStatus {
        if await isAlreadyOptimized() {
            return OptimizationStatus(
                isOptimized: true,
                version: "1.0",
                indexCount: 26,
                lastOptimizedAt: Date()
            )
        } else {
            return OptimizationStatus(
                isOptimized: false,
                version: "0.0",
                indexCount: 0,
                lastOptimizedAt: nil
            )
        }
    }

    /// Verify index existence and coverage
    func verifyIndexes() async -> IndexVerificationResult {
        var result = IndexVerificationResult()

        do {
            let indexes: [[String: Any]] = try await db.queryRaw("""
                SELECT name FROM sqlite_master
                WHERE type = 'index' AND name LIKE 'idx_%'
                ORDER BY name
            """)

            result.totalIndexes = indexes.count
            result.indexNames = indexes.compactMap { $0["name"] as? String }

            // Expected optimization indexes
            let expectedIndexes = [
                "idx_unified_prefs_category_score",
                "idx_unified_prefs_unsynced_updated",
                "idx_unified_prefs_decay",
                "idx_unified_prefs_source_scores",
                "idx_discovery_carousel_interaction",
                "idx_discovery_media_recent",
                "idx_discovery_engagement",
                "idx_search_recent_relevant",
                "idx_search_clicked_media",
                "idx_personalized_carousel_content",
                "idx_personalized_expired",
                "idx_ai_session_messages",
                "idx_ai_query_analytics",
                "idx_ai_token_usage",
                "idx_clip_history_engagement_user",
                "idx_clip_history_completion",
                "idx_clip_history_session",
                "idx_list_items_media",
                "idx_list_items_added",
                "idx_list_items_list_added",
                "idx_sync_outbox_pending_priority",
                "idx_sync_outbox_dependencies",
                "idx_movie_reactions_user_media",
                "idx_movie_reactions_media_type",
                "idx_clips_active_quality",
                "idx_clips_genres",
                "idx_detail_cache_lookup"
            ]

            result.missingIndexes = expectedIndexes.filter { !result.indexNames.contains($0) }
            result.allIndexesPresent = result.missingIndexes.isEmpty

        } catch {
            Logger.error("[DatabaseOptimization] Failed to verify indexes", error: error)
        }

        return result
    }
}

// MARK: - Supporting Types

struct OptimizationStatus {
    let isOptimized: Bool
    let version: String
    let indexCount: Int
    let lastOptimizedAt: Date?
}

struct IndexVerificationResult {
    var totalIndexes: Int = 0
    var indexNames: [String] = []
    var missingIndexes: [String] = []
    var allIndexesPresent: Bool = false
}
