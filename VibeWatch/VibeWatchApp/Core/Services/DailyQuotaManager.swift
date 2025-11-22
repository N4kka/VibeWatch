import Foundation
import SwiftUI

/// Manages daily clip quota for free users (15 clips/day)
@MainActor
class DailyQuotaManager: ObservableObject {
    static let shared = DailyQuotaManager()
    
    @Published var clipsWatchedToday: Int = 0
    @Published var isProUser: Bool = false
    @Published var lastResetDate: Date = Date()
    @Published var hasReachedLimit: Bool = false
    
    private let freeUserLimit = 15
    private let userDefaults = UserDefaults.standard
    
    // Keys for local storage
    private let clipsCountKey = "dailyClipsCount"
    private let lastResetKey = "lastQuotaReset"
    private let isProKey = "isProUser"
    private let deviceIdKey = "deviceIdentifier"
    
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
        loadQuotaData()
        checkAndResetIfNeeded()
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
        
        print("📊 [DailyQuota] Clips watched: \(clipsWatchedToday)/\(freeUserLimit)")
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
        
        print("✨ [DailyQuota] User upgraded to Pro!")
    }
    
    /// Reset quota (for testing or manual reset)
    func resetQuota() {
        clipsWatchedToday = 0
        lastResetDate = Date()
        hasReachedLimit = false
        saveQuotaData()
        
        print("🔄 [DailyQuota] Quota reset")
    }
    
    // MARK: - Private Methods
    
    /// Check if we need to reset the quota (midnight passed)
    private func checkAndResetIfNeeded() {
        let calendar = Calendar.current
        
        if !calendar.isDateInToday(lastResetDate) {
            print("🌅 [DailyQuota] New day detected, resetting quota")
            resetQuota()
        }
    }
    
    /// Load quota data from UserDefaults
    private func loadQuotaData() {
        clipsWatchedToday = userDefaults.integer(forKey: clipsCountKey)
        isProUser = userDefaults.bool(forKey: isProKey)
        
        if let savedDate = userDefaults.object(forKey: lastResetKey) as? Date {
            lastResetDate = savedDate
        }
        
        hasReachedLimit = clipsWatchedToday >= freeUserLimit && !isProUser
        
        print("📱 [DailyQuota] Loaded: \(clipsWatchedToday) clips watched today")
    }
    
    /// Save quota data to UserDefaults
    private func saveQuotaData() {
        userDefaults.set(clipsWatchedToday, forKey: clipsCountKey)
        userDefaults.set(isProUser, forKey: isProKey)
        userDefaults.set(lastResetDate, forKey: lastResetKey)
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
            
            print("☁️ [DailyQuota] Synced to Supabase")
        } catch {
            print("⚠️ [DailyQuota] Sync error: \(error)")
        }
    }
    
    /// Fetch quota from Supabase (for sync between devices)
    func fetchFromSupabase() async {
        guard let client = SupabaseService.shared.client else {
            return
        }
        
        let userId = SupabaseService.shared.currentUser?.id
        
        do {
            let query = userId != nil ?
                client.from("user_daily_quota").select().eq("user_id", value: userId!) :
                client.from("user_daily_quota").select().eq("device_id", value: deviceId)
            
            let response: [QuotaRow] = try await query.execute().value
            
            if let quota = response.first {
                clipsWatchedToday = quota.clipsWatchedToday
                isProUser = quota.isPro
                hasReachedLimit = clipsWatchedToday >= freeUserLimit && !isProUser
                saveQuotaData()
                
                print("☁️ [DailyQuota] Fetched from Supabase: \(clipsWatchedToday) clips")
            }
        } catch {
            print("⚠️ [DailyQuota] Fetch error: \(error)")
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
