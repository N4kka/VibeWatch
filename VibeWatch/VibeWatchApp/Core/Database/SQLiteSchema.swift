import Foundation

// The `CREATE TABLE` / `CREATE INDEX` string builders, extracted from SQLiteService (ARCH-007).
//
// This is ~600 lines of pure schema DDL that used to sit inside SQLiteService alongside the
// connection, execution and CRUD machinery. Mixing the two is what let PERF-001 hide: 73 declared
// indexes that were never created, buried under the schema text. Kept as an `extension SQLiteService`
// so callers (createTables / runMigrations) are untouched; the builders are now `internal` rather
// than `private` because they're defined in a different file of the same module.

extension SQLiteService {
    func createClipsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS clips (
          id TEXT PRIMARY KEY,
          clip_id TEXT UNIQUE NOT NULL,
          video_id TEXT NOT NULL,
          title TEXT NOT NULL,
          description TEXT,
          video_url TEXT NOT NULL,
          thumbnail_url TEXT,
          movie_id INTEGER,
          tv_show_id INTEGER,
          media_type TEXT,
          genres TEXT,
          actors TEXT,
          mood TEXT,
          keywords TEXT,
          likes INTEGER DEFAULT 0,
          comments INTEGER DEFAULT 0,
          views INTEGER DEFAULT 0,
          youtube_views INTEGER,
          tmdb_rating REAL,
          quality_score REAL,
          is_active INTEGER DEFAULT 1,
          is_premium INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          fetched_at TEXT DEFAULT (datetime('now')),
          last_served_at TEXT,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_clips_active ON clips(is_active, deleted_at);
        CREATE INDEX IF NOT EXISTS idx_clips_media_type ON clips(media_type);
        CREATE INDEX IF NOT EXISTS idx_clips_quality ON clips(quality_score DESC);
        CREATE INDEX IF NOT EXISTS idx_clips_created ON clips(created_at DESC);
        """
    }
    
    func createDiscoveryCacheTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS discovery_cache (
          id TEXT PRIMARY KEY,
          content_type TEXT NOT NULL,
          tmdb_id INTEGER NOT NULL,
          title TEXT NOT NULL,
          overview TEXT,
          poster_path TEXT,
          backdrop_path TEXT,
          vote_average REAL,
          release_date TEXT,
          genres TEXT,
          cached_at TEXT DEFAULT (datetime('now')),
          expires_at TEXT NOT NULL,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          UNIQUE(content_type, tmdb_id)
        );
        CREATE INDEX IF NOT EXISTS idx_discovery_content_type ON discovery_cache(content_type);
        CREATE INDEX IF NOT EXISTS idx_discovery_expires ON discovery_cache(expires_at);
        """
    }
    
    func createMediaDetailsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS media_details_cache (
          tmdb_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          title TEXT NOT NULL,
          overview TEXT,
          poster_path TEXT,
          backdrop_path TEXT,
          cached_at TEXT DEFAULT (datetime('now')),
          expires_at TEXT NOT NULL,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          PRIMARY KEY (tmdb_id, media_type)
        );
        """
    }

    func createDetailCacheTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS detail_cache (
          id TEXT PRIMARY KEY,
          media_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          title TEXT NOT NULL,
          overview TEXT,
          poster_path TEXT,
          backdrop_path TEXT,
          release_date TEXT,
          vote_average REAL,
          runtime INTEGER,
          genres TEXT,
          credits_json TEXT,
          videos_json TEXT,
          providers_json TEXT,
          similar_json TEXT,
          imdb_id TEXT,
          -- Il modello Codable intero: le colonne sopra restano per le query, questa per i
          -- campi che altrimenti la cache perderebbe (generi, stato, tagline, budget, network).
          model_json TEXT,
          cached_at TEXT DEFAULT (datetime('now')),
          expires_at TEXT NOT NULL,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          UNIQUE(media_id, media_type)
        );
        CREATE INDEX IF NOT EXISTS idx_detail_cache_media ON detail_cache(media_id, media_type);
        CREATE INDEX IF NOT EXISTS idx_detail_cache_expires ON detail_cache(expires_at);
        """
    }
    
    func createTrailersTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS trailers_cache (
          tmdb_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          youtube_id TEXT NOT NULL,
          trailer_type TEXT,
          name TEXT,
          cached_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          PRIMARY KEY (tmdb_id, media_type, youtube_id)
        );
        """
    }
    
    func createProfilesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS profiles (
          id TEXT PRIMARY KEY,
          email TEXT UNIQUE,
          display_name TEXT,
          avatar_url TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT
        );
        """
    }
    
    func createListsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS lists (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          name TEXT NOT NULL,
          description TEXT,
          type TEXT,
          is_public INTEGER NOT NULL DEFAULT 0,
          -- La lista da cui questa è stata copiata: la copia pubblica segue la sorgente.
          source_list_id TEXT,
          source_list_type TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_lists_user_id ON lists(user_id);
        CREATE INDEX IF NOT EXISTS idx_lists_deleted ON lists(deleted_at);
        """
    }

    // MARK: - Public Lists (Fase 1)

    /// Bookmark live verso liste pubbliche altrui (outbox → apply_mutations). `id` stabile per
    /// (user, list) così follow/unfollow riusano la stessa riga (soft-delete su deleted_at).
    func createListFollowsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS list_follows (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          list_id TEXT NOT NULL,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(user_id, list_id)
        );
        CREATE INDEX IF NOT EXISTS idx_list_follows_user ON list_follows(user_id);
        CREATE INDEX IF NOT EXISTS idx_list_follows_list ON list_follows(list_id);
        """
    }

    /// Blocco utente: le sue liste pubbliche spariscono dal feed.
    func createUserBlocksTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_blocks (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          blocked_user_id TEXT NOT NULL,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(user_id, blocked_user_id)
        );
        CREATE INDEX IF NOT EXISTS idx_user_blocks_user ON user_blocks(user_id);
        """
    }

    /// Segnalazione lista (insert-only, idempotente per coppia).
    func createListReportsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS list_reports (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          list_id TEXT NOT NULL,
          reason TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, list_id)
        );
        CREATE INDEX IF NOT EXISTS idx_list_reports_list ON list_reports(list_id);
        """
    }

    /// Cache leggero dei metadati delle liste pubbliche per la tab "Followed" offline.
    func createPublicListsCacheTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS public_lists_cache (
          list_id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          description TEXT,
          item_count INTEGER DEFAULT 0,
          cover_paths TEXT,
          updated_at TEXT,
          cached_at TEXT DEFAULT (datetime('now'))
        );
        """
    }
    
    func createListItemsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS list_items (
          id TEXT PRIMARY KEY,
          list_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          media_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          title TEXT NOT NULL,
          poster_path TEXT,
          runtime INTEGER,
          vote_average REAL,
          vote_count INTEGER,
          origin_country TEXT,
          release_date TEXT,
          genres TEXT,
          overview TEXT,
          added_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(list_id, media_id, media_type),
          FOREIGN KEY (list_id) REFERENCES lists(id) ON DELETE CASCADE,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_list_items_list_id ON list_items(list_id);
        CREATE INDEX IF NOT EXISTS idx_list_items_user_id ON list_items(user_id);
        """
    }
    
    func createUserClipHistoryTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_clip_history (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          clip_id TEXT NOT NULL,
          watched_at TEXT DEFAULT (datetime('now')),
          watch_duration REAL,
          total_duration REAL,
          completion_rate REAL,
          liked INTEGER DEFAULT 0,
          commented INTEGER DEFAULT 0,
          shared INTEGER DEFAULT 0,
          added_to_list INTEGER DEFAULT 0,
          engagement_score REAL,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(user_id, clip_id),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_history_user_id ON user_clip_history(user_id);
        CREATE INDEX IF NOT EXISTS idx_clip_history_watched_at ON user_clip_history(watched_at DESC);
        """
    }

    func createUserClipSignalsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_clip_signals (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          clip_id TEXT NOT NULL,
          signal_type TEXT NOT NULL,
          signal_value REAL,
          source TEXT,
          position INTEGER,
          session_id TEXT,
          occurred_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_signals_user_id ON user_clip_signals(user_id);
        CREATE INDEX IF NOT EXISTS idx_clip_signals_clip_id ON user_clip_signals(clip_id);
        """
    }
    
    func createUserPreferencesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_preferences (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          preference_type TEXT NOT NULL,
          preference_id TEXT NOT NULL,
          preference_name TEXT,
          score REAL DEFAULT 0,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(user_id, preference_type, preference_id),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_preferences_user_id ON user_preferences(user_id);
        """
    }
    
    func createUserDailyQuotaTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_daily_quota (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          clips_watched_today INTEGER DEFAULT 0,
          last_reset_at TEXT DEFAULT (datetime('now')),
          is_pro INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(user_id, device_id),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        """
    }
    
    func createUserAITokenUsageTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_ai_token_usage (
          id TEXT,
          user_id TEXT PRIMARY KEY,
          tokens_used_today INTEGER DEFAULT 0,
          last_reset_at TEXT,
          usage_day TEXT,
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT
        );
        """
    }

    
    func createSyncOutboxTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS sync_outbox (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          operation_id TEXT UNIQUE NOT NULL,
          user_id TEXT NOT NULL,
          table_name TEXT NOT NULL,
          operation_type TEXT NOT NULL,
          record_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          status TEXT DEFAULT 'pending',
          attempts INTEGER DEFAULT 0,
          max_attempts INTEGER DEFAULT 5,
          created_at TEXT DEFAULT (datetime('now')),
          next_retry_at TEXT,
          synced_at TEXT,
          last_error TEXT,
          depends_on_id INTEGER,
          FOREIGN KEY (depends_on_id) REFERENCES sync_outbox(id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_outbox_status ON sync_outbox(status, next_retry_at);
        CREATE INDEX IF NOT EXISTS idx_outbox_user_id ON sync_outbox(user_id);
        """
    }
    
    func createSyncLogTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS sync_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sync_batch_id TEXT NOT NULL,
          operation_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          table_name TEXT NOT NULL,
          operation_type TEXT NOT NULL,
          status TEXT NOT NULL,
          error_message TEXT,
          synced_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_sync_log_batch ON sync_log(sync_batch_id);
        CREATE INDEX IF NOT EXISTS idx_sync_log_timestamp ON sync_log(synced_at DESC);
        """
    }
    
    func createDeviceInfoTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS device_info (
          device_id TEXT PRIMARY KEY,
          user_id TEXT,
          device_name TEXT,
          platform TEXT,
          app_version TEXT,
          last_sync_at TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now'))
        );
        """
    }
    
    func createAppMetadataTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS app_metadata (
          key_name TEXT PRIMARY KEY,
          value_text TEXT,
          value_number REAL,
          value_boolean INTEGER,
          value_json TEXT,
          updated_at TEXT DEFAULT (datetime('now'))
        );
        """
    }
    
    // MARK: - Reactions & Comments Tables
    
    func createMovieReactionsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS movie_reactions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          media_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          reaction_type TEXT NOT NULL,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          UNIQUE(user_id, media_id, media_type),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_movie_reactions_user ON movie_reactions(user_id);
        CREATE INDEX IF NOT EXISTS idx_movie_reactions_media ON movie_reactions(media_id, media_type);
        """
    }
    
    func createMovieReactionCountsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS movie_reaction_counts (
          media_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          like_count INTEGER DEFAULT 0,
          dislike_count INTEGER DEFAULT 0,
          updated_at TEXT DEFAULT (datetime('now')),
          PRIMARY KEY (media_id, media_type)
        );
        """
    }
    
    func createClipReactionsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS clip_reactions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          clip_id TEXT NOT NULL,
          reaction_type TEXT NOT NULL DEFAULT 'like',
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, clip_id, reaction_type),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_reactions_user ON clip_reactions(user_id);
        CREATE INDEX IF NOT EXISTS idx_clip_reactions_clip ON clip_reactions(clip_id);
        """
    }
    
    func createClipCommentsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS clip_comments (
          id TEXT PRIMARY KEY,
          clip_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          parent_comment_id TEXT,
          content TEXT NOT NULL,
          like_count INTEGER DEFAULT 0,
          reply_count INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE,
          FOREIGN KEY (parent_comment_id) REFERENCES clip_comments(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_comments_clip ON clip_comments(clip_id, deleted_at);
        CREATE INDEX IF NOT EXISTS idx_clip_comments_parent ON clip_comments(parent_comment_id);
        CREATE INDEX IF NOT EXISTS idx_clip_comments_user ON clip_comments(user_id);
        """
    }
    
    func createClipCommentLikesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS clip_comment_likes (
          id TEXT PRIMARY KEY,
          comment_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          created_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, comment_id),
          FOREIGN KEY (comment_id) REFERENCES clip_comments(id) ON DELETE CASCADE,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_comment_likes_comment ON clip_comment_likes(comment_id);
        CREATE INDEX IF NOT EXISTS idx_clip_comment_likes_user ON clip_comment_likes(user_id);
        CREATE INDEX IF NOT EXISTS idx_clip_comment_likes_user_comment ON clip_comment_likes(user_id, comment_id);
        """
    }

    // MARK: - Gamification Tables

    func createUserGamificationTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_gamification (
          user_id TEXT PRIMARY KEY,
          total_xp INTEGER DEFAULT 0,
          current_level INTEGER DEFAULT 1,
          current_streak INTEGER DEFAULT 0,
          longest_streak INTEGER DEFAULT 0,
          last_activity_date TEXT,
          streak_freezes_remaining INTEGER DEFAULT 0,
          streak_freezes_used_this_week INTEGER DEFAULT 0,
          week_start_date TEXT,
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        """
    }

    func createUserBadgesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_badges (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          badge_id TEXT NOT NULL,
          progress INTEGER DEFAULT 0,
          target INTEGER NOT NULL,
          unlocked_at TEXT,
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, badge_id),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_user_badges_user ON user_badges(user_id);
        CREATE INDEX IF NOT EXISTS idx_user_badges_unlocked ON user_badges(unlocked_at);
        """
    }

    func createUserDailyChallengesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_daily_challenges (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          challenge_date TEXT NOT NULL,
          challenge_type TEXT NOT NULL,
          challenge_description TEXT,
          target INTEGER NOT NULL,
          progress INTEGER DEFAULT 0,
          completed_at TEXT,
          xp_reward INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, challenge_date),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_daily_challenges_user ON user_daily_challenges(user_id);
        CREATE INDEX IF NOT EXISTS idx_daily_challenges_date ON user_daily_challenges(challenge_date);
        """
    }

    func createXPTransactionsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS xp_transactions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          action_type TEXT NOT NULL,
          base_xp INTEGER NOT NULL,
          multiplier REAL DEFAULT 1.0,
          streak_bonus REAL DEFAULT 0.0,
          total_xp INTEGER NOT NULL,
          source TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_xp_transactions_user ON xp_transactions(user_id);
        CREATE INDEX IF NOT EXISTS idx_xp_transactions_created ON xp_transactions(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_xp_transactions_action ON xp_transactions(action_type);
        """
    }
}
