import Foundation
import Supabase
import RevenueCat

/// Tracks quota for ANONYMOUS users and RevenueCat Pro status.
/// For logged-in user clip counting, use DailyQuotaManager.shared instead.
///
/// Responsibilities:
/// - Anonymous user clip tracking (15 clips before account creation)
/// - RevenueCat Pro subscription status
/// - Automatic Pro/Free downgrade detection
@MainActor
final class ClipQuotaService: ObservableObject {
    static let shared = ClipQuotaService()
    
    // MARK: - Published Properties
    
    /// Number of clips watched by anonymous (not logged in) users
    @Published private(set) var anonymousClipsWatched: Int
    
    /// Whether user has active Pro subscription (from RevenueCat)
    @Published private(set) var isProUser: Bool = false
    
    // MARK: - Constants
    
    private let anonymousLimit = 15
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let anonymousClipsWatched = "clip_quota_anonymous_clips_watched"
    }
    
    // MARK: - Dependencies
    
    private let supabase = SupabaseService.shared
    private var customerInfoStreamTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    private init() {
        self.anonymousClipsWatched = defaults.integer(forKey: Keys.anonymousClipsWatched)
        observeRevenueCatCustomerInfo()
        
        Task { [weak self] in
            _ = await self?.checkIsProUser()
        }
        
        debugPrintStatus()
    }
    
    // MARK: - Anonymous User Tracking
    
    /// Returns true if an anonymous user can watch another clip.
    func canWatchClipAnonymous() -> Bool {
        anonymousClipsWatched < anonymousLimit
    }
    
    /// Records a clip watch for an anonymous user. Call this as soon as a clip starts.
    func recordClipWatchedAnonymous() {
        guard canWatchClipAnonymous() else { return }
        
        anonymousClipsWatched += 1
        defaults.set(anonymousClipsWatched, forKey: Keys.anonymousClipsWatched)
        
        debugPrintStatus()
    }
    
    /// Clears the anonymous counter, typically after the user signs up.
    func resetAnonymousCounter() {
        anonymousClipsWatched = 0
        defaults.removeObject(forKey: Keys.anonymousClipsWatched)
        
        debugPrintStatus()
    }
    
    /// Returns the gate type to show for the current anonymous state.
    func gateTypeForAnonymousUser() -> ClipGateType? {
        canWatchClipAnonymous() ? nil : .accountCreation
    }
    
    // MARK: - RevenueCat Pro Status
    
    /// Returns true if the RevenueCat "StartingVibe Pro" entitlement is active.
    @discardableResult
    func checkIsProUser() async -> Bool {
        do {
            let info = try await Purchases.shared.customerInfo()
            let isPro = info.entitlements["StartingVibe Pro"]?.isActive == true
            
            updateProStatus(isPro)
            return isPro
        } catch {
            print("❌ [ClipQuota] Failed to fetch RevenueCat customer info: \(error.localizedDescription)")
            return isProUser
        }
    }
    
    // MARK: - Private Helpers
    
    /// Observes RevenueCat customer info stream for subscription status changes
    private func observeRevenueCatCustomerInfo() {
        customerInfoStreamTask?.cancel()
        customerInfoStreamTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                let isPro = info.entitlements["StartingVibe Pro"]?.isActive == true
                await MainActor.run {
                    self?.updateProStatus(isPro)
                }
            }
        }
    }
    
    /// Updates Pro status and triggers appropriate actions on status change
    private func updateProStatus(_ newValue: Bool) {
        guard isProUser != newValue else { return }
        
        let wasProBefore = isProUser
        isProUser = newValue
        
        if !newValue && wasProBefore {
            // Downgraded from Pro to Free
            print("⬇️ [ClipQuota] Subscription expired - downgrading to Free")
            DailyQuotaManager.shared.downgradeToFree()
            
            // Analytics
            Task { @MainActor in
                AnalyticsService.shared.logEvent("subscription_expired", parameters: [:])
            }
            
            // Sync to database
            Task {
                await syncStatusToDatabase()
            }
        } else if newValue && !wasProBefore {
            // Upgraded from Free to Pro
            print("⬆️ [ClipQuota] Subscription activated")
            DailyQuotaManager.shared.upgradeToPro()
            
            // Analytics
            Task { @MainActor in
                AnalyticsService.shared.logEvent("subscription_activated", parameters: [:])
            }
            
            // Sync to database
            Task {
                await syncStatusToDatabase()
            }
        }
    }
    
    /// Sync Pro status to database
    private func syncStatusToDatabase() async {
        guard let userId = supabase.currentUser?.id else { return }
        guard let client = supabase.client else { return }
        
        struct StatusUpdate: Encodable {
            let user_id: String
            let is_pro: Bool
            let updated_at: String
        }
        
        let update = StatusUpdate(
            user_id: userId,
            is_pro: isProUser,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        
        do {
            try await client
                .from("user_daily_quota")
                .upsert(update, onConflict: "user_id")
                .execute()
            
            print("☁️ [ClipQuota] Pro status synced to database: \(isProUser)")
        } catch {
            print("⚠️ [ClipQuota] Failed to sync Pro status: \(error)")
        }
    }
    
    /// Debug logging of current quota state
    private func debugPrintStatus() {
        print("📊 [ClipQuota] Anonymous clips watched: \(anonymousClipsWatched)/\(anonymousLimit)")
        print("💎 [ClipQuota] Pro status: \(isProUser ? "ACTIVE" : "inactive")")
    }
}

// MARK: - Gate Types

/// Possible gates to show after exhausting clip limits.
enum ClipGateType {
    case accountCreation    // Show "create account" gate (anonymous users)
    case proPaywall         // Show Pro paywall (logged-in free users)
}
