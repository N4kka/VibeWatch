import Foundation
import Combine
import UIKit

/// Manages AI request quotas and usage tracking.
/// Enforces daily limits: 5 (Free) vs 10 (Pro).
@MainActor
final class AITokenManager: ObservableObject {
    static let shared = AITokenManager()

    // MARK: - Constants
    private let freeLimit = AppConstants.AI.freeDailyRequestLimit
    private let proLimit = AppConstants.AI.proDailyRequestLimit
    private let db = SQLiteService.shared
    private let legacyStorageKey = "vibe_watch_ai_token_usage"
    
    // MARK: - State
    @Published private(set) var tokensUsedToday: Int = 0
    @Published private(set) var dailyLimit: Int = 5
    
    private var lastResetDate: Date = Date()
    private var dayChangeObserver: NSObjectProtocol?
    
    private init() {
        updateLimit()
        startDayChangeMonitoring()
        Task {
            await migrateFromUserDefaultsIfNeeded()
            await loadUsageFromSQLite()
            checkAndResetDaily()
        }
    }
    
    deinit {
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
        }
    }
    
    // MARK: - Public API
    
    /// Checks if the user has enough remaining quota for a request.
    func canMakeRequest() -> Bool {
        checkAndResetDaily()
        return tokensUsedToday < dailyLimit
    }
    
    /// Updates tokens from a remote source.
    func syncTokens(_ count: Int) {
        checkAndResetDaily()
        // If we just reset for a new day, ignore older remote counts that might be from "yesterday"
        // unless we know for sure they are for today. 
        // SupabaseService already handles the day boundary check, so we can trust it.
        self.tokensUsedToday = count
        saveUsage()
    }
    
    /// Records a completed AI request.
    func recordUsage(_ tokens: Int = 1) {
        checkAndResetDaily()
        
        // We treat each AI message as one request for quota purposes.
        // Remote usage is recorded by the Cerebras proxy after a successful response.
        tokensUsedToday += 1
        saveUsage()
    }
    
    /// Returns the remaining requests for today.
    var remainingTokens: Int {
        return max(0, dailyLimit - tokensUsedToday)
    }
    
    /// Updates the daily limit based on subscription status.
    /// Call this when subscription state changes.
    func updateLimit() {
        let isPro = DailyQuotaManager.shared.isProUser
        dailyLimit = EntitlementPolicy.aiDailyLimit(for: isPro ? .pro : .free)
    }
    
    // MARK: - Internal Logic
    
    private func startDayChangeMonitoring() {
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkAndResetDaily()
            }
        }
    }
    
    private func checkAndResetDaily() {
        let calendar = Calendar.current
        if !calendar.isDateInToday(lastResetDate) {
            Logger.info("[AITokenManager] New day detected. Resetting quota.")
            tokensUsedToday = 0
            lastResetDate = Date()
            saveUsage()
        }
    }
    
    // MARK: - Persistence (SQLite)

    /// One-time migration from UserDefaults to SQLite
    private func migrateFromUserDefaultsIfNeeded() async {
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey) else { return }

        struct LegacyData: Codable { let tokens: Int; let date: Date }
        guard let decoded = try? JSONDecoder().decode(LegacyData.self, from: data) else { return }

        let userId = SupabaseService.shared.currentUser?.id ?? "anonymous"
        do {
            let sql = """
                REPLACE INTO user_ai_token_usage (id, user_id, tokens_used_today, last_reset_at, updated_at)
                VALUES (?, ?, ?, ?, datetime('now'))
            """
            _ = try await db.queryRaw(sql, parameters: [
                userId, userId, decoded.tokens,
                ISO8601DateFormatter().string(from: decoded.date)
            ])
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
            Logger.info("[AITokenManager] Migrated token usage from UserDefaults to SQLite")
        } catch {
            Logger.error("[AITokenManager] Migration failed: \(error)")
        }
    }

    private func loadUsageFromSQLite() async {
        do {
            let userId = SupabaseService.shared.currentUser?.id ?? "anonymous"
            let result = try await db.queryRaw(
                "SELECT tokens_used_today, last_reset_at FROM user_ai_token_usage WHERE user_id = ? LIMIT 1",
                parameters: [userId]
            )
            if let row = result.first {
                tokensUsedToday = row["tokens_used_today"] as? Int ?? 0
                if let str = row["last_reset_at"] as? String,
                   let date = ISO8601DateFormatter().date(from: str) {
                    lastResetDate = date
                }
            }
        } catch {
            Logger.error("[AITokenManager] Failed to load from SQLite: \(error)")
        }
    }

    private func saveUsage() {
        Task { await saveUsageToSQLite() }
    }

    private func saveUsageToSQLite() async {
        do {
            let userId = SupabaseService.shared.currentUser?.id ?? "anonymous"
            let sql = """
                REPLACE INTO user_ai_token_usage (id, user_id, tokens_used_today, last_reset_at, updated_at)
                VALUES (?, ?, ?, ?, datetime('now'))
            """
            _ = try await db.queryRaw(sql, parameters: [
                userId, userId, tokensUsedToday,
                ISO8601DateFormatter().string(from: lastResetDate)
            ])
        } catch {
            Logger.error("[AITokenManager] Failed to save to SQLite: \(error)")
        }
    }
}
