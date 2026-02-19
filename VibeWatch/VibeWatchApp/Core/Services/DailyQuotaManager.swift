import Foundation
import SwiftUI
import UIKit

/// Manages daily clip quota for free users (25 clips/day)
@MainActor
class DailyQuotaManager: ObservableObject {
    static let shared = DailyQuotaManager()
    
    @Published var clipsWatchedToday: Int = 0
    @Published var isProUser: Bool = false
    @Published var lastResetDate: Date = Date()
    @Published var hasReachedLimit: Bool = false
    
    private let freeUserLimit = AppConstants.Clips.freeUserDailyLimit
    private let userDefaults = UserDefaults.standard
    private let db = SQLiteService.shared

    // App settings keys (kept in UserDefaults per architecture principles)
    private let isProKey = "isProUser"
    private let deviceIdKey = "deviceIdentifier"

    private var dayChangeObserver: NSObjectProtocol?
    
    // Device identifier for anonymous tracking
    private var deviceId: String {
        if let existing = userDefaults.string(forKey: deviceIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        userDefaults.set(newId, forKey: deviceIdKey)
        return newId
    }
    
    private init() {
        // Load pro status from UserDefaults (app setting)
        isProUser = userDefaults.bool(forKey: isProKey)
        // Load quota from SQLite, with one-time migration
        Task {
            await migrateFromUserDefaultsIfNeeded()
            await loadQuotaFromSQLite()
            checkAndResetIfNeeded()
        }
        startDayChangeMonitoring()
        
        #if DEBUG
        // Debug-only: force Pro to allow AI feature testing.
        // Toggle off by setting this flag to false if you need to re-enable paywalls in Debug.
        let forcePro = AppConstants.Debug.forceProUser
        if forcePro && !isProUser {
            Logger.debug("[DailyQuota] DEBUG MODE: Forcing Pro user for testing")
            isProUser = true
            hasReachedLimit = false
            saveQuotaData()
        }
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Check if user can watch more clips today
    func canWatchMoreClips() -> Bool {
        if isProUser {
            return true
        }
        return clipsWatchedToday < freeUserLimit
    }
    
    /// Get remaining clips for today
    func remainingClips() -> Int {
        if isProUser {
            return Int.max
        }
        return max(0, freeUserLimit - clipsWatchedToday)
    }
    
    /// Increment clip count when user watches a clip
    func recordClipWatched() {
        guard !isProUser else { return }

        clipsWatchedToday += 1
        hasReachedLimit = clipsWatchedToday >= freeUserLimit
        saveQuotaData()

        // Sync to Supabase in background
        Task {
            await syncToSupabase()
        }
        
        Logger.debug("[DailyQuota] Clips watched: \(clipsWatchedToday)/\(freeUserLimit)")
    }
    
    /// Time until quota resets (for countdown timer)
    func timeUntilReset() -> TimeInterval {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
              let midnight = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow) else {
            return 0
        }
        return midnight.timeIntervalSince(Date())
    }
    
    /// Format time until reset as string (e.g., "8h 23m")
    func timeUntilResetFormatted() -> String {
        let timeInterval = timeUntilReset()
        let hours = Int(timeInterval) / 3600
        let minutes = (Int(timeInterval) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    /// Upgrade to Pro (removes limits)
    func upgradeToPro() {
        isProUser = true
        hasReachedLimit = false
        saveQuotaData()
        
        Task {
            await syncToSupabase()
        }
        
        Logger.info("[DailyQuota] User upgraded to Pro")
    }
    
    /// Downgrade to Free (restores limits)
    func downgradeToFree() {
        isProUser = false
        hasReachedLimit = clipsWatchedToday >= freeUserLimit
        saveQuotaData()
        
        Task {
            await syncToSupabase()
        }
        
        let remaining = remainingClips()
        Logger.info("[DailyQuota] Downgraded to Free - \(remaining) clips remaining today")

        if remaining == 0 {
            Logger.info("[DailyQuota] Daily limit already reached - user will see paywall")
        }
    }
    
    /// Reset quota (for testing or manual reset)
    func resetQuota() {
        clipsWatchedToday = 0
        lastResetDate = Date()
        hasReachedLimit = false
        saveQuotaData()
        
        Logger.debug("[DailyQuota] Quota reset")
    }

    /// Call when the app becomes active to enforce local-midnight resets.
    func refreshForNewDayIfNeeded() {
        checkAndResetIfNeeded()
        Task {
            await SupabaseService.shared.handleLocalDayBoundaryForCurrentUser()
        }
    }
    
    // MARK: - Private Methods
    
    /// Check if we need to reset the quota (midnight passed)
    private func checkAndResetIfNeeded() {
        let calendar = Calendar.current
        
        if !calendar.isDateInToday(lastResetDate) {
            Logger.info("[DailyQuota] New day detected, resetting quota")
            resetQuota()
        }
    }

    private func startDayChangeMonitoring() {
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Logger.debug("[DailyQuota] Significant time change detected - rechecking daily resets")
            self.refreshForNewDayIfNeeded()
        }
    }
    
    /// One-time migration from UserDefaults to SQLite
    private func migrateFromUserDefaultsIfNeeded() async {
        let legacyClipsKey = "dailyClipsCount"
        let legacyResetKey = "lastQuotaReset"
        guard userDefaults.object(forKey: legacyClipsKey) != nil else { return }

        let oldCount = userDefaults.integer(forKey: legacyClipsKey)
        let oldReset = userDefaults.object(forKey: legacyResetKey) as? Date ?? Date()
        let userId = SupabaseService.shared.currentUser?.id ?? "anonymous"
        let quotaId = "\(userId)_\(deviceId)"

        do {
            let sql = """
                REPLACE INTO user_daily_quota (id, user_id, device_id, clips_watched_today, last_reset_at, is_pro, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
            """
            _ = try await db.queryRaw(sql, parameters: [
                quotaId, userId, deviceId, oldCount,
                ISO8601DateFormatter().string(from: oldReset),
                isProUser ? 1 : 0
            ])
            userDefaults.removeObject(forKey: legacyClipsKey)
            userDefaults.removeObject(forKey: legacyResetKey)
            Logger.info("[DailyQuota] Migrated quota data from UserDefaults to SQLite")
        } catch {
            Logger.error("[DailyQuota] Migration failed: \(error)")
        }
    }

    /// Load quota data from SQLite
    private func loadQuotaFromSQLite() async {
        do {
            let userId = SupabaseService.shared.currentUser?.id ?? "anonymous"
            let result = try await db.queryRaw(
                "SELECT clips_watched_today, last_reset_at FROM user_daily_quota WHERE user_id = ? AND device_id = ? LIMIT 1",
                parameters: [userId, deviceId]
            )
            if let row = result.first {
                clipsWatchedToday = row["clips_watched_today"] as? Int ?? 0
                if let str = row["last_reset_at"] as? String,
                   let date = ISO8601DateFormatter().date(from: str) {
                    lastResetDate = date
                }
                hasReachedLimit = clipsWatchedToday >= freeUserLimit && !isProUser
                Logger.debug("[DailyQuota] Loaded from SQLite: \(clipsWatchedToday) clips watched today")
            }
        } catch {
            Logger.error("[DailyQuota] Failed to load from SQLite: \(error)")
        }
    }

    /// Save quota data - pro status to UserDefaults (app setting), quota to SQLite (user data)
    private func saveQuotaData() {
        userDefaults.set(isProUser, forKey: isProKey)
        Task { await saveQuotaToSQLite() }
    }

    /// Save quota data to SQLite
    private func saveQuotaToSQLite() async {
        do {
            let userId = SupabaseService.shared.currentUser?.id ?? "anonymous"
            let quotaId = "\(userId)_\(deviceId)"
            let sql = """
                REPLACE INTO user_daily_quota (id, user_id, device_id, clips_watched_today, last_reset_at, is_pro, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
            """
            _ = try await db.queryRaw(sql, parameters: [
                quotaId, userId, deviceId, clipsWatchedToday,
                ISO8601DateFormatter().string(from: lastResetDate),
                isProUser ? 1 : 0
            ])
        } catch {
            Logger.error("[DailyQuota] Failed to save to SQLite: \(error)")
        }
    }
    
    /// Sync quota to Supabase (for server-side tracking)
    private func syncToSupabase() async {
        guard let client = SupabaseService.shared.client else {
            return
        }
        
        let userId = SupabaseService.shared.currentUser?.id
        
        // Create quota row struct
        struct QuotaUpdate: Encodable {
            let device_id: String?
            let user_id: String?
            let clips_watched_today: Int
            let is_pro: Bool
            let last_reset_at: String
            let updated_at: String
        }
        
        let quotaUpdate = QuotaUpdate(
            device_id: userId == nil ? deviceId : nil,
            user_id: userId,
            clips_watched_today: clipsWatchedToday,
            is_pro: isProUser,
            last_reset_at: ISO8601DateFormatter().string(from: lastResetDate),
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        
        do {
            // Specify which column to use for conflict resolution
            let conflictColumn = userId != nil ? "user_id" : "device_id"
            
            // Try upsert (insert or update)
            try await client
                .from("user_daily_quota")
                .upsert(quotaUpdate, onConflict: conflictColumn)
                .execute()
            
            Logger.debug("[DailyQuota] Synced to Supabase")
        } catch {
            Logger.warning("[DailyQuota] Sync error: \(error)")
        }
    }
    
    /// Fetch quota from Supabase (for sync between devices)
    func fetchFromSupabase() async {
        guard let client = SupabaseService.shared.client else {
            return
        }
        
        let userId = SupabaseService.shared.currentUser?.id
        
        do {
            let response: [QuotaRow]
            if let userId = userId {
                response = try await client.from("user_daily_quota").select().eq("user_id", value: userId).execute().value
            } else {
                response = try await client.from("user_daily_quota").select().eq("device_id", value: deviceId).execute().value
            }
            
            if let quota = response.first {
                clipsWatchedToday = quota.clipsWatchedToday
                isProUser = quota.isPro
                hasReachedLimit = clipsWatchedToday >= freeUserLimit && !isProUser
                saveQuotaData()
                
                Logger.debug("[DailyQuota] Fetched from Supabase: \(clipsWatchedToday) clips")
            }
        } catch {
            Logger.warning("[DailyQuota] Fetch error: \(error)")
        }
    }
}

// MARK: - Supabase Response Model

private struct QuotaRow: Codable {
    let clipsWatchedToday: Int
    let isPro: Bool
    
    enum CodingKeys: String, CodingKey {
        case clipsWatchedToday = "clips_watched_today"
        case isPro = "is_pro"
    }
}
