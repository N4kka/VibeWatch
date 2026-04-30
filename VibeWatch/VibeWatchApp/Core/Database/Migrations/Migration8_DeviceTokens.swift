import Foundation

extension SQLiteService {
    func migration8_AddDeviceTokensTable() {
        Logger.info("[SQLite] Migration 8: Creating device_tokens table for APNs token storage")

        execute(createDeviceTokensTable())

        Logger.info("[SQLite] Migration 8 complete - device_tokens table created")
    }

    private func createDeviceTokensTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS device_tokens (
            token TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            platform TEXT NOT NULL DEFAULT 'ios',
            locale TEXT,
            timezone TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            last_seen_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON device_tokens(user_id);
        """
    }
}
