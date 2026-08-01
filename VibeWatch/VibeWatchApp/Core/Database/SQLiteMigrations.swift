import Foundation
import SQLite3

/// SQLite migration system for user preferences and personalization
/// Phase 1: Database Foundation - User Preferences & Personalization Architecture
extension SQLiteService {

    /// Run personalization migrations (Phase 1)
    func runPersonalizationMigrations() {
        let currentVersion = getPersonalizationMigrationVersion()
        let latestVersion = 12

        guard currentVersion < latestVersion else {
            Logger.info("[SQLite] Personalization migrations already applied (version \(currentVersion))")
            return
        }

        Logger.info("[SQLite] Running personalization migrations from version \(currentVersion) to \(latestVersion)...")

        // Temporarily disable foreign keys for migration
        execute("PRAGMA foreign_keys = OFF")

        // Start transaction
        execute("BEGIN TRANSACTION")

        do {
            if currentVersion < 1 {
                migration1_CreatePersonalizationTables()
            }
            if currentVersion < 2 {
                migration2_AddCerebrasJobQueueAndEmbeddings()
            }
            if currentVersion < 3 {
                migration3_AddJobMetrics()
            }
            if currentVersion < 4 {
                migration4_AddTimeOfDayPatterns()
            }
            if currentVersion < 5 {
                migration5_AddSmartNotifications()
            }
            if currentVersion < 6 {
                migration6_AddNotificationSubscriptions()
            }
            if currentVersion < 7 {
                migration7_BackfillMissingIndexes()
            }
            if currentVersion < 8 {
                migration8_AddTrackingTables()
            }
            if currentVersion < 9 {
                migration9_AddTrackingViewMirrors()
            }
            if currentVersion < 10 {
                migration10_AddUserFollows()
            }
            if currentVersion < 11 {
                migration11_AddFavoritesAndRatings()
            }
            if currentVersion < 12 {
                migration12_AddLocalizedTitles()
            }

            // Update migration version
            execute("""
                INSERT OR REPLACE INTO app_metadata (key_name, value_text)
                VALUES ('personalization_migration_version', '\(latestVersion)')
            """)

            execute("COMMIT")
            Logger.info("[SQLite] Personalization migrations complete - now at version \(latestVersion)")

        } catch {
            execute("ROLLBACK")
            Logger.error("[SQLite] Migration failed, rolled back", error: error)
        }

        // Re-enable foreign keys
        execute("PRAGMA foreign_keys = ON")
    }

    private func getPersonalizationMigrationVersion() -> Int {
        var versionString = "0"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, "SELECT value_text FROM app_metadata WHERE key_name = 'personalization_migration_version'", -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                if let versionPtr = sqlite3_column_text(statement, 0) {
                    versionString = String(cString: versionPtr)
                }
            }
            sqlite3_finalize(statement)
        }

        return Int(versionString) ?? 0
    }

    // MARK: - Migration 1: User Preferences & Personalization Tables

    private func migration1_CreatePersonalizationTables() {
        Logger.info("[SQLite] Migration 1: Creating user preferences & personalization tables")

        // 1. user_search_history
        executeScript(createUserSearchHistoryTable())

        // 2. user_discovery_interactions
        executeScript(createUserDiscoveryInteractionsTable())

        // 3. unified_user_preferences (CRITICAL)
        executeScript(createUnifiedUserPreferencesTable())

        // 4. personalized_discovery
        executeScript(createPersonalizedDiscoveryTable())

        // 5. ai_conversation_history
        executeScript(createAIConversationHistoryTable())

        // 6. global_discovery_filters
        executeScript(createGlobalDiscoveryFiltersTable())

        // 7. Modify existing user_preferences table
        migrateExistingUserPreferences()

        // 8. Modify existing user_clip_history table
        migrateExistingUserClipHistory()

        // 9. Modify existing clips table
        migrateExistingClipsTable()

        Logger.info("[SQLite] Migration 1 complete - all personalization tables created")
    }

    // MARK: - Migration 2: Cerebras Backend Jobs + Embeddings

    private func migration2_AddCerebrasJobQueueAndEmbeddings() {
        Logger.info("[SQLite] Migration 2: Creating Cerebras job queue + embeddings tables")

        executeScript(createCerebrasJobQueueTable())
        executeScript(createMediaEmbeddingsTable())
        executeScript(createUserBehaviorInsightsTable())

        Logger.info("[SQLite] Migration 2 complete - Cerebras backend tables created")
    }

    // MARK: - Migration 3: Job Metrics & Monitoring

    private func migration3_AddJobMetrics() {
        Logger.info("[SQLite] Migration 3: Creating job metrics table for monitoring")

        executeScript(createCerebrasJobMetricsTable())

        Logger.info("[SQLite] Migration 3 complete - Job metrics table created")
    }

    // MARK: - Migration 4: Time-of-Day Pattern Detection

    private func migration4_AddTimeOfDayPatterns() {
        Logger.info("[SQLite] Migration 4: Creating time-of-day pattern tracking table")

        executeScript(createUserTimePatternsTable())

        Logger.info("[SQLite] Migration 4 complete - Time pattern tracking enabled")
    }

    // MARK: - Migration 5: Smart Notifications

    private func migration5_AddSmartNotifications() {
        Logger.info("[SQLite] Migration 5: Creating smart notification tables")

        executeScript(createNotificationHistoryTable())
        executeScript(createUserNotificationPreferencesTable())

        Logger.info("[SQLite] Migration 5 complete - Smart notifications enabled")
    }

    // MARK: - Migration 6: Notification Subscriptions (Pro Feature)

    private func migration6_AddNotificationSubscriptions() {
        Logger.info("[SQLite] Migration 6: Creating notification subscriptions table for Pro features")

        executeScript(createNotificationSubscriptionsTable())

        Logger.info("[SQLite] Migration 6 complete - Pro notification subscriptions enabled")
    }

    // MARK: - Migration 7: Backfill indexes lost to prepare_v2

    /// Migrations 1-6 created their tables with `execute`, which compiles only the first statement
    /// of a string. Every CREATE INDEX that followed a CREATE TABLE in the same script was
    /// discarded, so these tables have run without indexes since they were introduced. The scripts
    /// are re-run through `executeScript`; every statement in them is IF NOT EXISTS, so existing
    /// tables and data are untouched and only the missing indexes get built.
    private func migration7_BackfillMissingIndexes() {
        Logger.info("[SQLite] Migration 7: Backfilling indexes dropped by prepare_v2")

        executeScript(createUserSearchHistoryTable())
        executeScript(createUserDiscoveryInteractionsTable())
        executeScript(createUnifiedUserPreferencesTable())
        executeScript(createPersonalizedDiscoveryTable())
        executeScript(createAIConversationHistoryTable())
        executeScript(createGlobalDiscoveryFiltersTable())
        executeScript(createCerebrasJobQueueTable())
        executeScript(createMediaEmbeddingsTable())
        executeScript(createUserBehaviorInsightsTable())
        executeScript(createCerebrasJobMetricsTable())
        executeScript(createUserTimePatternsTable())
        executeScript(createNotificationHistoryTable())
        executeScript(createUserNotificationPreferencesTable())
        executeScript(createNotificationSubscriptionsTable())

        Logger.info("[SQLite] Migration 7 complete - indexes backfilled")
    }

    /// SPEC v3 §4 — lo specchio locale del tracking episodi.
    ///
    /// `watch_events` è append-only e la strategia di conflitto è `union`: non si perde mai una
    /// visione. `tv_show_state` è derivato e il server è autorevole (§1.1), quindi in locale è solo
    /// una cache di lettura — ciò che il client può cambiare è `user_status`, e passa dall'outbox.
    private func migration8_AddTrackingTables() {
        Logger.info("[SQLite] Migration 8: Adding watch_events and tv_show_state")

        executeScript(createWatchEventsTable())
        executeScript(createTVShowStateTable())

        Logger.info("[SQLite] Migration 8 complete")
    }

    /// SPEC v3 §9.2 / §13.6 — lo specchio locale delle due viste della schermata Tracking.
    ///
    /// Non sono tabelle di dominio ma **cache di righe già pronte per la UI**: le calcola il
    /// server (`v_tv_tracking`, `v_tv_timeline`), il client le ritira e le legge. Nessuna delle
    /// due passa dall'outbox — non c'è niente da rimandare indietro, perché ciò che l'utente può
    /// cambiare (`user_status`, gli eventi di visione) ha già le sue tabelle.
    ///
    /// Il motivo per cui esistono è §13.6: la schermata deve disegnarsi da qui, senza rete, sotto
    /// i 300 ms. Se per mostrare la lista servisse una chiamata, il lavoro sarebbe sbagliato.
    private func migration9_AddTrackingViewMirrors() {
        Logger.info("[SQLite] Migration 9: Adding tv_tracking and tv_timeline mirrors")

        executeScript(createTVTrackingMirrorTable())
        executeScript(createTVTimelineMirrorTable())

        Logger.info("[SQLite] Migration 9 complete")
    }

    /// SPEC v3 §3.6 — lo specchio locale di `user_follows`.
    ///
    /// Strategia `union` (§4): un follow non si perde mai. La chiave e' la coppia, identica al
    /// server — niente id sintetico. La scrittura passa dall'outbox (`apply_mutations` ha il suo
    /// ramo dal 2026-07-31); il pull riporta indietro anche le righe in cui si e' il followee,
    /// che servono a "chi mi segue".
    private func migration10_AddUserFollows() {
        Logger.info("[SQLite] Migration 10: Adding user_follows")

        executeScript(createUserFollowsTable())

        Logger.info("[SQLite] Migration 10 complete")
    }

    /// SPEC v3 §3.6 (blocco 9) — lo specchio locale di `user_favorites` e `user_ratings`.
    ///
    /// Entrambe `lastWriteWins` (§4): l'ultimo intento dell'utente. Il soft delete viaggia come
    /// contenuto della riga (uno slot svuotato, un voto tolto), quindi il pull lo porta anche
    /// agli altri dispositivi.
    ///
    /// `user_ratings` sul server ha `season_number`/`episode_number` NULL per film e serie. Qui
    /// sono `NOT NULL DEFAULT -1`: una PK SQLite con una colonna NULL considera ogni NULL diverso
    /// dagli altri, quindi lo stesso voto arriverebbe due volte come due righe. Il -1 e' lo stesso
    /// sentinello del `coalesce(season_number,-1)` nell'indice unico del server — la chiave
    /// locale e quella remota coincidono per costruzione. La conversione NULL → -1 la fa
    /// `normalizeRow` nel pull; il percorso di scrittura (le azioni) parla al server con i NULL.
    private func migration11_AddFavoritesAndRatings() {
        Logger.info("[SQLite] Migration 11: Adding user_favorites and user_ratings")

        executeScript(createUserFavoritesTable())
        executeScript(createUserRatingsTable())

        Logger.info("[SQLite] Migration 11 complete")
    }

    /// La cache dei titoli nella lingua dell'app.
    ///
    /// Il catalogo condiviso (§1.5) parla una lingua sola — l'inglese di TMDB — e lo specchio
    /// `tv_tracking` la eredita. La schermata Tracking però ha il budget di §13.6: zero rete per
    /// disegnarsi. Quindi i titoli localizzati vivono qui, persistenti: il primo fotogramma fa
    /// una JOIN locale (titolo localizzato se c'è, quello del catalogo altrimenti), e un task in
    /// background riempie i buchi via TMDB nella lingua dell'app. Cache locale e basta: niente
    /// sync, niente pull-list — ogni dispositivo se la riempie da sé nella propria lingua.
    private func migration12_AddLocalizedTitles() {
        Logger.info("[SQLite] Migration 12: Adding localized_titles")

        executeScript(createLocalizedTitlesTable())

        Logger.info("[SQLite] Migration 12 complete")
    }

    // MARK: - Table Creation Methods

    private func createLocalizedTitlesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS localized_titles (
            media_type TEXT NOT NULL,
            tmdb_id INTEGER NOT NULL,
            language TEXT NOT NULL,
            title TEXT NOT NULL,
            updated_at TEXT,
            PRIMARY KEY (media_type, tmdb_id, language)
        );
        """
    }

    private func createUserFavoritesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_favorites (
            user_id TEXT NOT NULL,
            media_type TEXT NOT NULL,
            slot INTEGER NOT NULL,
            tmdb_id INTEGER NOT NULL,
            updated_at TEXT,
            deleted_at TEXT,
            synced_at TEXT,
            PRIMARY KEY (user_id, media_type, slot)
        );
        """
    }

    private func createUserRatingsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_ratings (
            user_id TEXT NOT NULL,
            media_type TEXT NOT NULL,
            tmdb_id INTEGER NOT NULL,
            season_number INTEGER NOT NULL DEFAULT -1,
            episode_number INTEGER NOT NULL DEFAULT -1,
            rating INTEGER NOT NULL,
            created_at TEXT,
            updated_at TEXT,
            deleted_at TEXT,
            synced_at TEXT,
            PRIMARY KEY (user_id, media_type, tmdb_id, season_number, episode_number)
        );
        """
    }

    private func createUserFollowsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_follows (
            follower_id TEXT NOT NULL,
            followee_id TEXT NOT NULL,
            created_at TEXT,
            deleted_at TEXT,
            synced_at TEXT,
            PRIMARY KEY (follower_id, followee_id)
        );
        -- La PK copre "chi seguo"; questo copre "chi mi segue".
        CREATE INDEX IF NOT EXISTS idx_user_follows_followee
            ON user_follows(followee_id);
        """
    }

    private func createTVTrackingMirrorTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS tv_tracking (
            user_id TEXT NOT NULL,
            tmdb_show_id INTEGER NOT NULL,
            user_status TEXT NOT NULL DEFAULT 'active',
            watched_count INTEGER NOT NULL DEFAULT 0,
            aired_count INTEGER NOT NULL DEFAULT 0,
            total_count INTEGER NOT NULL DEFAULT 0,
            last_watched_at TEXT,
            next_season INTEGER,
            next_episode INTEGER,
            next_air_date TEXT,
            backlog_since TEXT,
            first_watched_at TEXT,
            completed_at TEXT,
            updated_at TEXT,
            synced_at TEXT,
            bucket TEXT,
            is_next_available INTEGER,
            show_name TEXT,
            show_poster_path TEXT,
            show_status TEXT,
            next_episode_name TEXT,
            next_still_path TEXT,
            next_runtime_minutes INTEGER,
            PRIMARY KEY (user_id, tmdb_show_id)
        );
        -- L'ordinamento della schermata: bucket, poi arretrato piu' recente in cima (§3.3).
        CREATE INDEX IF NOT EXISTS idx_tv_tracking_bucket
            ON tv_tracking(user_id, bucket, backlog_since DESC);
        """
    }

    private func createTVTimelineMirrorTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS tv_timeline (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            tmdb_show_id INTEGER NOT NULL,
            show_name TEXT,
            show_poster_path TEXT,
            season_number INTEGER NOT NULL,
            episode_number INTEGER NOT NULL,
            episode_name TEXT,
            air_date TEXT,
            still_path TEXT,
            is_special INTEGER NOT NULL DEFAULT 0
        );
        -- La timeline si legge in ordine di uscita e basta.
        CREATE INDEX IF NOT EXISTS idx_tv_timeline_air_date
            ON tv_timeline(user_id, air_date);
        """
    }

    private func createWatchEventsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS watch_events (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            media_type TEXT NOT NULL,
            tmdb_movie_id INTEGER,
            tmdb_show_id INTEGER,
            season_number INTEGER,
            episode_number INTEGER,
            watched_at TEXT NOT NULL,
            logged_at TEXT,
            watched_at_precision TEXT NOT NULL DEFAULT 'exact',
            runtime_seconds INTEGER,
            is_special INTEGER NOT NULL DEFAULT 0,
            rewatch_index INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'manual',
            external_ref TEXT,
            dedup_key TEXT,
            device_id TEXT,
            deleted_at TEXT,
            synced_at TEXT
        );
        -- Il diario: eventi di un utente in ordine cronologico inverso. È l'unica lettura calda
        -- di questa tabella sul client, ed è quella che deve stare sotto i 300 ms (§13.6).
        CREATE INDEX IF NOT EXISTS idx_watch_events_user_watched
            ON watch_events(user_id, watched_at DESC);
        -- Il progresso di una singola serie, per la schermata di dettaglio.
        CREATE INDEX IF NOT EXISTS idx_watch_events_user_show
            ON watch_events(user_id, tmdb_show_id, season_number, episode_number);
        -- La dedup locale prima di accodare un evento all'outbox: stessa chiave del server, così
        -- un re-import non genera 20.000 mutazioni destinate a essere scartate a destinazione.
        CREATE INDEX IF NOT EXISTS idx_watch_events_dedup
            ON watch_events(user_id, dedup_key);
        """
    }

    private func createTVShowStateTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS tv_show_state (
            user_id TEXT NOT NULL,
            tmdb_show_id INTEGER NOT NULL,
            user_status TEXT NOT NULL DEFAULT 'active',
            watched_count INTEGER NOT NULL DEFAULT 0,
            aired_count INTEGER NOT NULL DEFAULT 0,
            total_count INTEGER NOT NULL DEFAULT 0,
            last_watched_at TEXT,
            next_season INTEGER,
            next_episode INTEGER,
            next_air_date TEXT,
            backlog_since TEXT,
            first_watched_at TEXT,
            completed_at TEXT,
            updated_at TEXT,
            synced_at TEXT,
            PRIMARY KEY (user_id, tmdb_show_id)
        );
        -- L'ordinamento della schermata Tracking: prima chi ha un arretrato più vecchio.
        CREATE INDEX IF NOT EXISTS idx_tv_show_state_user_backlog
            ON tv_show_state(user_id, user_status, backlog_since);
        """
    }

    private func createCerebrasJobQueueTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS cerebras_job_queue (
            id TEXT PRIMARY KEY,
            job_type TEXT NOT NULL,
            payload_json TEXT,
            status TEXT NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0,
            max_attempts INTEGER NOT NULL DEFAULT 3,
            priority INTEGER NOT NULL DEFAULT 0,
            scheduled_at TEXT,
            started_at TEXT,
            completed_at TEXT,
            last_error TEXT,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cerebras_jobs_status ON cerebras_job_queue(status, priority DESC, created_at ASC);
        CREATE INDEX IF NOT EXISTS idx_cerebras_jobs_scheduled ON cerebras_job_queue(status, scheduled_at);
        """
    }

    private func createMediaEmbeddingsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS media_embeddings (
            media_type TEXT NOT NULL,
            media_id INTEGER NOT NULL,
            model TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            vector_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (media_type, media_id, model)
        );
        CREATE INDEX IF NOT EXISTS idx_media_embeddings_lookup ON media_embeddings(media_type, media_id);
        """
    }

    private func createUserBehaviorInsightsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_behavior_insights (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            insights_json TEXT NOT NULL,
            generated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_behavior_insights_user ON user_behavior_insights(user_id, generated_at DESC);
        """
    }

    private func createCerebrasJobMetricsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS cerebras_job_metrics (
            id TEXT PRIMARY KEY,
            job_type TEXT NOT NULL,
            success INTEGER NOT NULL DEFAULT 0,
            duration_seconds REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 1,
            executed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_job_metrics_type ON cerebras_job_metrics(job_type, executed_at DESC);
        CREATE INDEX IF NOT EXISTS idx_job_metrics_executed ON cerebras_job_metrics(executed_at DESC);
        CREATE INDEX IF NOT EXISTS idx_job_metrics_success ON cerebras_job_metrics(success, executed_at DESC);
        """
    }

    private func createUserTimePatternsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_time_patterns (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            time_of_day TEXT NOT NULL,
            engagement_score REAL NOT NULL,
            recorded_at TEXT NOT NULL,
            FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_time_patterns_user ON user_time_patterns(user_id, time_of_day);
        CREATE INDEX IF NOT EXISTS idx_time_patterns_recorded ON user_time_patterns(recorded_at DESC);
        """
    }

    private func createNotificationHistoryTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS notification_history (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            notification_type TEXT NOT NULL,
            content_id TEXT NOT NULL,
            sent_at TEXT NOT NULL,
            clicked INTEGER DEFAULT 0,
            dismissed INTEGER DEFAULT 0,
            UNIQUE(user_id, notification_type, content_id)
        );
        CREATE INDEX IF NOT EXISTS idx_notification_history_user ON notification_history(user_id, sent_at DESC);
        CREATE INDEX IF NOT EXISTS idx_notification_history_type ON notification_history(notification_type, sent_at DESC);
        """
    }

    private func createUserNotificationPreferencesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_notification_preferences (
            user_id TEXT PRIMARY KEY,
            enable_new_episodes INTEGER DEFAULT 1,
            enable_release_alerts INTEGER DEFAULT 1,
            enable_actor_alerts INTEGER DEFAULT 1,
            enable_similar_content INTEGER DEFAULT 1,
            enable_watchlist_alerts INTEGER DEFAULT 1,
            enable_milestones INTEGER DEFAULT 1,
            max_daily_notifications INTEGER DEFAULT 3,
            quiet_hours_start INTEGER DEFAULT 22,
            quiet_hours_end INTEGER DEFAULT 8,
            custom_actor_alerts TEXT,
            custom_genre_alerts TEXT,
            updated_at TEXT NOT NULL
        );
        """
    }

    private func createNotificationSubscriptionsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS notification_subscriptions (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            actor_id INTEGER,
            genre_id INTEGER,
            type TEXT NOT NULL CHECK (type IN ('actor_alert', 'genre_alert')),
            created_at TEXT NOT NULL,
            synced_at TEXT,
            FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_notification_subscriptions_user ON notification_subscriptions(user_id, type);
        CREATE INDEX IF NOT EXISTS idx_notification_subscriptions_actor ON notification_subscriptions(actor_id) WHERE actor_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_notification_subscriptions_genre ON notification_subscriptions(genre_id) WHERE genre_id IS NOT NULL;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_subscriptions_user_actor ON notification_subscriptions(user_id, actor_id, type) WHERE actor_id IS NOT NULL;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_subscriptions_user_genre ON notification_subscriptions(user_id, genre_id, type) WHERE genre_id IS NOT NULL;
        """
    }

    private func createUserSearchHistoryTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_search_history (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            query TEXT NOT NULL,
            media_type TEXT,
            result_count INTEGER,
            clicked_media_id INTEGER,
            clicked_media_title TEXT,
            searched_at TEXT NOT NULL,
            relevance_score REAL DEFAULT 1.0,
            synced_at TEXT,
            UNIQUE(user_id, query, searched_at)
        );
        CREATE INDEX IF NOT EXISTS idx_search_history_user ON user_search_history(user_id, searched_at DESC);
        CREATE INDEX IF NOT EXISTS idx_search_relevance ON user_search_history(user_id, relevance_score DESC);
        CREATE INDEX IF NOT EXISTS idx_search_sync ON user_search_history(synced_at) WHERE synced_at IS NULL;
        """
    }

    private func createUserDiscoveryInteractionsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_discovery_interactions (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            media_id INTEGER NOT NULL,
            media_type TEXT NOT NULL,
            carousel_type TEXT NOT NULL,
            interaction_type TEXT NOT NULL,
            interacted_at TEXT NOT NULL,
            session_duration INTEGER,
            filter_active BOOLEAN DEFAULT 0,
            filter_config TEXT,
            synced_at TEXT,
            UNIQUE(user_id, media_id, media_type, interaction_type, interacted_at)
        );
        CREATE INDEX IF NOT EXISTS idx_discovery_interactions_user ON user_discovery_interactions(user_id, interacted_at DESC);
        CREATE INDEX IF NOT EXISTS idx_discovery_carousel ON user_discovery_interactions(carousel_type, interaction_type);
        CREATE INDEX IF NOT EXISTS idx_discovery_media ON user_discovery_interactions(media_id, media_type);
        CREATE INDEX IF NOT EXISTS idx_discovery_sync ON user_discovery_interactions(synced_at) WHERE synced_at IS NULL;
        """
    }

    private func createUnifiedUserPreferencesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS unified_user_preferences (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            preference_category TEXT NOT NULL,
            preference_id TEXT NOT NULL,
            preference_name TEXT,
            score REAL NOT NULL DEFAULT 0.0,
            score_from_clips REAL DEFAULT 0.0,
            score_from_discovery REAL DEFAULT 0.0,
            score_from_search REAL DEFAULT 0.0,
            score_from_ai REAL DEFAULT 0.0,
            score_from_lists REAL DEFAULT 0.0,
            interaction_count INTEGER DEFAULT 0,
            last_interaction_at TEXT,
            last_decay_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            synced_at TEXT,
            UNIQUE(user_id, preference_category, preference_id),
            FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_unified_prefs_user ON unified_user_preferences(user_id, preference_category, score DESC);
        CREATE INDEX IF NOT EXISTS idx_unified_prefs_sync ON unified_user_preferences(synced_at) WHERE synced_at IS NULL;
        CREATE INDEX IF NOT EXISTS idx_unified_prefs_updated ON unified_user_preferences(user_id, updated_at DESC);
        """
    }

    private func createPersonalizedDiscoveryTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS personalized_discovery (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            carousel_type TEXT NOT NULL,
            carousel_title TEXT NOT NULL,
            carousel_title_spec TEXT,
            media_id INTEGER NOT NULL,
            media_type TEXT NOT NULL,
            media_data TEXT,
            position INTEGER,
            score REAL,
            reason TEXT,
            description TEXT,
            generated_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            UNIQUE(user_id, carousel_type, media_id)
        );
        CREATE INDEX IF NOT EXISTS idx_personalized_discovery ON personalized_discovery(user_id, carousel_type, position);
        CREATE INDEX IF NOT EXISTS idx_personalized_expires ON personalized_discovery(expires_at);
        CREATE INDEX IF NOT EXISTS idx_personalized_generated ON personalized_discovery(generated_at DESC);
        """
    }

    private func createAIConversationHistoryTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS ai_conversation_history (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            message_type TEXT NOT NULL,
            content TEXT NOT NULL,
            query_type TEXT,
            mentioned_media_ids TEXT,
            mentioned_genres TEXT,
            tokens_used INTEGER,
            created_at TEXT NOT NULL,
            FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_ai_history_session ON ai_conversation_history(session_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_ai_history_user ON ai_conversation_history(user_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_ai_history_type ON ai_conversation_history(query_type);
        """
    }

    private func createGlobalDiscoveryFiltersTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS global_discovery_filters (
            user_id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            media_type TEXT,
            runtime_min INTEGER,
            runtime_max INTEGER,
            rating_min REAL,
            rating_max REAL,
            release_year_start INTEGER,
            release_year_end INTEGER,
            countries TEXT,
            sort_by TEXT,
            hide_watched BOOLEAN DEFAULT 0,
            hide_disliked BOOLEAN DEFAULT 0,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_filters_updated ON global_discovery_filters(updated_at DESC);
        """
    }

    // MARK: - Existing Table Migrations

    private func migrateExistingUserPreferences() {
        // Add new columns to user_preferences if they don't exist
        if !columnExists("user_preferences", column: "source") {
            execute("ALTER TABLE user_preferences ADD COLUMN source TEXT")
            Logger.info("[SQLite] Added 'source' column to user_preferences")
        }

        if !columnExists("user_preferences", column: "interaction_count") {
            execute("ALTER TABLE user_preferences ADD COLUMN interaction_count INTEGER DEFAULT 0")
            Logger.info("[SQLite] Added 'interaction_count' column to user_preferences")
        }

        if !columnExists("user_preferences", column: "last_decay_at") {
            execute("ALTER TABLE user_preferences ADD COLUMN last_decay_at TEXT")
            Logger.info("[SQLite] Added 'last_decay_at' column to user_preferences")
        }

        // Migrate existing data to unified_user_preferences
        execute("""
            INSERT OR IGNORE INTO unified_user_preferences (
                id, user_id, device_id, preference_category, preference_id,
                preference_name, score, score_from_clips, interaction_count,
                created_at, updated_at
            )
            SELECT
                id,
                user_id,
                device_id,
                preference_type as preference_category,
                preference_id,
                preference_name,
                score,
                score as score_from_clips,
                COALESCE(interaction_count, 1) as interaction_count,
                COALESCE(updated_at, datetime('now')) as created_at,
                updated_at
            FROM user_preferences
            WHERE deleted_at IS NULL
        """)

        Logger.info("[SQLite] Migrated existing user_preferences to unified_user_preferences")
    }

    private func migrateExistingUserClipHistory() {
        if !columnExists("user_clip_history", column: "session_id") {
            execute("ALTER TABLE user_clip_history ADD COLUMN session_id TEXT")
            Logger.info("[SQLite] Added 'session_id' column to user_clip_history")
        }

        // Note: synced_at already exists in user_clip_history
    }

    private func migrateExistingClipsTable() {
        if !columnExists("clips", column: "ai_description") {
            execute("ALTER TABLE clips ADD COLUMN ai_description TEXT")
            Logger.info("[SQLite] Added 'ai_description' column to clips")
        }

        if !columnExists("clips", column: "mood_tags") {
            execute("ALTER TABLE clips ADD COLUMN mood_tags TEXT")
            Logger.info("[SQLite] Added 'mood_tags' column to clips")
        }
    }
}

// MARK: - Helper Methods for Personalization

extension SQLiteService {

    /// Get device ID (create if not exists)
    func getOrCreateDeviceId() async -> String {
        do {
            let rows: [[String: Any]] = try await queryRaw("""
                SELECT device_id FROM device_info LIMIT 1
            """)

            if let deviceId = rows.first?["device_id"] as? String {
                return deviceId
            }
        } catch {
            Logger.error("[SQLite] Failed to get device_id", error: error)
        }

        // Create new device ID
        let newDeviceId = UUID().uuidString.lowercased()
        execute("""
            INSERT OR REPLACE INTO device_info (device_id, platform, created_at, updated_at)
            VALUES ('\(newDeviceId)', 'ios', datetime('now'), datetime('now'))
        """)

        return newDeviceId
    }

    /// Track search query
    func trackSearch(
        userId: String,
        query: String,
        mediaType: String? = nil,
        resultCount: Int,
        clickedMediaId: Int? = nil,
        clickedMediaTitle: String? = nil
    ) async throws {
        let deviceId = await getOrCreateDeviceId()
        let id = generateUUID()

        _ = try await insert("user_search_history", values: [
            "id": id,
            "user_id": userId,
            "device_id": deviceId,
            "query": query,
            "media_type": mediaType ?? NSNull(),
            "result_count": resultCount,
            "clicked_media_id": clickedMediaId ?? NSNull(),
            "clicked_media_title": clickedMediaTitle ?? NSNull(),
            "searched_at": ISO8601DateFormatter().string(from: Date()),
            "relevance_score": 1.0
        ])

        Logger.debug("[SQLite] Tracked search: '\(query)' (\(resultCount) results)")
    }

    /// Track discovery interaction
    func trackDiscoveryInteraction(
        userId: String,
        mediaId: Int,
        mediaType: String,
        carouselType: String,
        interactionType: String,
        sessionDuration: Int? = nil,
        filterActive: Bool = false,
        filterConfig: String? = nil
    ) async throws {
        let deviceId = await getOrCreateDeviceId()
        let id = generateUUID()

        _ = try await insert("user_discovery_interactions", values: [
            "id": id,
            "user_id": userId,
            "device_id": deviceId,
            "media_id": mediaId,
            "media_type": mediaType,
            "carousel_type": carouselType,
            "interaction_type": interactionType,
            "interacted_at": ISO8601DateFormatter().string(from: Date()),
            "session_duration": sessionDuration ?? NSNull(),
            "filter_active": filterActive ? 1 : 0,
            "filter_config": filterConfig ?? NSNull()
        ])

        Logger.debug("[SQLite] Tracked discovery interaction: \(interactionType) on \(mediaType) #\(mediaId)")
    }

    /// Update unified preference score
    func updateUnifiedPreference(
        userId: String,
        category: String,
        preferenceId: String,
        preferenceName: String,
        scoreIncrement: Double,
        source: String
    ) async throws {
        let deviceId = await getOrCreateDeviceId()
        let now = ISO8601DateFormatter().string(from: Date())

        // Check if preference exists
        let existing: [[String: Any]] = try await queryRaw("""
            SELECT id, score, score_from_clips, score_from_discovery,
                   score_from_search, score_from_ai, score_from_lists,
                   interaction_count
            FROM unified_user_preferences
            WHERE user_id = ? AND preference_category = ? AND preference_id = ?
        """, parameters: [userId, category, preferenceId])

        if let existingRow = existing.first {
            // Update existing preference
            let currentScore = existingRow["score"] as? Double ?? 0.0
            let currentInteractionCount = existingRow["interaction_count"] as? Int ?? 0

            var sourceField = "score_from_clips"
            switch source {
            case "discovery": sourceField = "score_from_discovery"
            case "search": sourceField = "score_from_search"
            case "ai": sourceField = "score_from_ai"
            case "lists": sourceField = "score_from_lists"
            default: break
            }

            let currentSourceScore = existingRow[sourceField] as? Double ?? 0.0

            try await update("unified_user_preferences",
                values: [
                    "score": currentScore + scoreIncrement,
                    sourceField: currentSourceScore + scoreIncrement,
                    "interaction_count": currentInteractionCount + 1,
                    "last_interaction_at": now,
                    "updated_at": now
                ],
                where: "user_id = ? AND preference_category = ? AND preference_id = ?",
                parameters: [userId, category, preferenceId]
            )
        } else {
            // Create new preference
            let id = generateUUID()
            var values: [String: Any] = [
                "id": id,
                "user_id": userId,
                "device_id": deviceId,
                "preference_category": category,
                "preference_id": preferenceId,
                "preference_name": preferenceName,
                "score": scoreIncrement,
                "score_from_clips": 0.0,
                "score_from_discovery": 0.0,
                "score_from_search": 0.0,
                "score_from_ai": 0.0,
                "score_from_lists": 0.0,
                "interaction_count": 1,
                "last_interaction_at": now,
                "created_at": now,
                "updated_at": now
            ]

            switch source {
            case "clips": values["score_from_clips"] = scoreIncrement
            case "discovery": values["score_from_discovery"] = scoreIncrement
            case "search": values["score_from_search"] = scoreIncrement
            case "ai": values["score_from_ai"] = scoreIncrement
            case "lists": values["score_from_lists"] = scoreIncrement
            default: values["score_from_clips"] = scoreIncrement
            }

            _ = try await insert("unified_user_preferences", values: values)
        }

        Logger.debug("[SQLite] Updated unified preference: \(category):\(preferenceId) += \(scoreIncrement) from \(source)")
    }

    /// Get top preferences for user
    func getTopPreferences(
        userId: String,
        category: String,
        limit: Int = 10
    ) async throws -> [[String: Any]] {
        return try await queryRaw("""
            SELECT preference_id, preference_name, score,
                   score_from_clips, score_from_discovery, score_from_search,
                   score_from_ai, score_from_lists, interaction_count,
                   last_interaction_at
            FROM unified_user_preferences
            WHERE user_id = ? AND preference_category = ?
            ORDER BY score DESC
            LIMIT ?
        """, parameters: [userId, category, limit])
    }

    /// Track AI conversation
    func trackAIConversation(
        userId: String,
        sessionId: String,
        messageType: String,
        content: String,
        queryType: String? = nil,
        mentionedMediaIds: [Int]? = nil,
        mentionedGenres: [String]? = nil,
        tokensUsed: Int? = nil
    ) async throws {
        let deviceId = await getOrCreateDeviceId()
        let id = generateUUID()

        var mentionedMediaIdsJSON: String? = nil
        if let ids = mentionedMediaIds, !ids.isEmpty {
            mentionedMediaIdsJSON = try? String(data: JSONEncoder().encode(ids), encoding: .utf8)
        }

        var mentionedGenresJSON: String? = nil
        if let genres = mentionedGenres, !genres.isEmpty {
            mentionedGenresJSON = try? String(data: JSONEncoder().encode(genres), encoding: .utf8)
        }

        _ = try await insert("ai_conversation_history", values: [
            "id": id,
            "user_id": userId,
            "device_id": deviceId,
            "session_id": sessionId,
            "message_type": messageType,
            "content": content,
            "query_type": queryType ?? NSNull(),
            "mentioned_media_ids": mentionedMediaIdsJSON ?? NSNull(),
            "mentioned_genres": mentionedGenresJSON ?? NSNull(),
            "tokens_used": tokensUsed ?? NSNull(),
            "created_at": ISO8601DateFormatter().string(from: Date())
        ])
    }
}
