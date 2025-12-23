import Foundation
import Combine
import UIKit

/// Manages AI request quotas and usage tracking.
/// Enforces daily limits: 5 (Free) vs 20 (Pro).
@MainActor
final class AITokenManager: ObservableObject {
    static let shared = AITokenManager()

    // MARK: - Constants
    private let freeLimit = AppConstants.AI.freeDailyRequestLimit
    private let proLimit = AppConstants.AI.proDailyRequestLimit
    private let storageKey = "vibe_watch_ai_token_usage"
    
    // MARK: - State
    @Published private(set) var tokensUsedToday: Int = 0
    @Published private(set) var dailyLimit: Int = 5
    
    private var lastResetDate: Date = Date()
    private var dayChangeObserver: NSObjectProtocol?
    
    private init() {
        loadUsage()
        updateLimit()
        startDayChangeMonitoring()
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
        
        // We now treat each AI message as 1 "token" (request) for simplicity
        // as requested: 0/5 for free, 0/20 for pro.
        tokensUsedToday += 1
        saveUsage()
        
        // Sync to Supabase in background
        if let user = SupabaseService.shared.currentUser {
            let userIdString = "\(user.id)"
            if let userId = UUID(uuidString: userIdString) {
                Task {
                    let newTotal = try? await SupabaseService.shared.logAITokenUsage(userId: userId, tokensConsumed: 1)
                    if let newTotal {
                        await MainActor.run {
                            self.syncTokens(newTotal)
                        }
                    }
                }
            }
        }
    }
    
    /// Returns the remaining requests for today.
    var remainingTokens: Int {
        return max(0, dailyLimit - tokensUsedToday)
    }
    
    /// Updates the daily limit based on subscription status.
    /// Call this when subscription state changes.
    func updateLimit() {
        let isPro = DailyQuotaManager.shared.isProUser
        dailyLimit = isPro ? proLimit : freeLimit
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
    
    // MARK: - Persistence
    
    private struct StorageData: Codable {
        let tokens: Int
        let date: Date
    }
    
    private func loadUsage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(StorageData.self, from: data) else {
            return
        }
        
        self.tokensUsedToday = decoded.tokens
        self.lastResetDate = decoded.date
        
        // Immediate check in case app was opened on a new day
        checkAndResetDaily()
    }
    
    private func saveUsage() {
        let data = StorageData(tokens: tokensUsedToday, date: lastResetDate)
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
