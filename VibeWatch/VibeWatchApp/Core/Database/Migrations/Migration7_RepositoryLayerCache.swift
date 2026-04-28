import Foundation

extension SQLiteService {
    func migration7_AddRepositoryLayerCache() {
        Logger.info("[SQLite] Migration 7: Creating repository layer cache tables")

        execute(createMediaAvailabilityTable())
        execute(createDiscoveryCarouselsTable())
        execute(createDiscoveryCarouselItemsTable())
        execute(createNotificationEventsTable())
        migrateMediaDetailsCacheTTLColumns()

        Logger.info("[SQLite] Migration 7 complete - Repository layer cache tables created")
    }

    private func migrateMediaDetailsCacheTTLColumns() {
        if !columnExists("media_details_cache", column: "metadata_expires_at") {
            execute("ALTER TABLE media_details_cache ADD COLUMN metadata_expires_at TEXT")
            execute("UPDATE media_details_cache SET metadata_expires_at = expires_at WHERE metadata_expires_at IS NULL")
            Logger.info("[SQLite] Added 'metadata_expires_at' column to media_details_cache")
        }

        if !columnExists("media_details_cache", column: "availability_expires_at") {
            execute("ALTER TABLE media_details_cache ADD COLUMN availability_expires_at TEXT")
            execute("UPDATE media_details_cache SET availability_expires_at = expires_at WHERE availability_expires_at IS NULL")
            Logger.info("[SQLite] Added 'availability_expires_at' column to media_details_cache")
        }
    }

    private func createMediaAvailabilityTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS media_availability (
            tmdb_id INTEGER NOT NULL,
            media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv')),
            region TEXT NOT NULL DEFAULT 'US',
            providers_json TEXT NOT NULL,
            cached_at TEXT NOT NULL DEFAULT (datetime('now')),
            expires_at TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT,
            PRIMARY KEY (tmdb_id, media_type, region)
        );
        CREATE INDEX IF NOT EXISTS idx_media_availability_expires ON media_availability(expires_at);
        CREATE INDEX IF NOT EXISTS idx_media_availability_lookup ON media_availability(tmdb_id, media_type, region);
        """
    }

    private func createDiscoveryCarouselsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS discovery_carousels (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            carousel_type TEXT NOT NULL,
            title TEXT NOT NULL,
            media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv', 'mixed')),
            filters_json TEXT,
            position INTEGER NOT NULL,
            cached_at TEXT NOT NULL DEFAULT (datetime('now')),
            expires_at TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT,
            UNIQUE(user_id, carousel_type, media_type)
        );
        CREATE INDEX IF NOT EXISTS idx_discovery_carousels_user ON discovery_carousels(user_id, position);
        CREATE INDEX IF NOT EXISTS idx_discovery_carousels_expires ON discovery_carousels(expires_at);
        """
    }

    private func createDiscoveryCarouselItemsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS discovery_carousel_items (
            id TEXT PRIMARY KEY,
            carousel_id TEXT NOT NULL,
            tmdb_id INTEGER NOT NULL,
            media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv')),
            position INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT,
            FOREIGN KEY (carousel_id) REFERENCES discovery_carousels(id) ON DELETE CASCADE,
            UNIQUE(carousel_id, tmdb_id, media_type)
        );
        CREATE INDEX IF NOT EXISTS idx_discovery_carousel_items_carousel ON discovery_carousel_items(carousel_id, position);
        CREATE INDEX IF NOT EXISTS idx_discovery_carousel_items_media ON discovery_carousel_items(tmdb_id, media_type);
        """
    }

    private func createNotificationEventsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS notification_events (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            event_key TEXT NOT NULL,
            channel TEXT NOT NULL CHECK (channel IN ('local_reminder', 'local_digest', 'remote_push')),
            notification_type TEXT NOT NULL,
            media_id INTEGER,
            media_type TEXT,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            scheduled_for TEXT,
            sent_at TEXT,
            opened_at TEXT,
            dismissed_at TEXT,
            payload_json TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(user_id, event_key, channel)
        );
        CREATE INDEX IF NOT EXISTS idx_notification_events_user ON notification_events(user_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_notification_events_dedupe ON notification_events(user_id, event_key, channel);
        CREATE INDEX IF NOT EXISTS idx_notification_events_scheduled ON notification_events(scheduled_for);
        """
    }
}
