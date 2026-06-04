import Foundation
import Supabase
import RevenueCat

/// Tracks quota for ANONYMOUS users and RevenueCat Pro status.
/// For logged-in user clip counting, use DailyQuotaManager.shared instead.
///
/// Responsibilities:
/// - Anonymous user clip tracking (25 clips before account creation)
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

    private let anonymousLimit = AppConstants.Clips.freeUserDailyLimit
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let anonymousClipsWatched = "clip_quota_anonymous_clips_watched"
        static let cachedProStatus = "clip_quota_cached_pro_status"
    }
    
    // MARK: - Dependencies
    
    private let supabase = SupabaseService.shared
    private var customerInfoStreamTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    private init() {
        self.anonymousClipsWatched = defaults.integer(forKey: Keys.anonymousClipsWatched)

        // Load cached PRO status for offline mode
        // Only load from cache if the key exists (otherwise wait for RevenueCat)
        if defaults.object(forKey: Keys.cachedProStatus) != nil {
            self.isProUser = defaults.bool(forKey: Keys.cachedProStatus)
            Logger.debug("[ClipQuota] Loaded cached PRO status: \(isProUser)")
        } else {
            Logger.debug("[ClipQuota] No cached PRO status - will check RevenueCat")
        }

        observeRevenueCatCustomerInfo()

        Task { [weak self] in
            _ = await self?.checkIsProUser()
        }

        debugPrintStatus()
    }
    
    // MARK: - Anonymous User Tracking
    
    /// Returns true if an anonymous user can watch another clip.
    func canWatchClipAnonymous() -> Bool {
        EntitlementPolicy.canConsumeClip(tier: .anonymous, clipsWatched: anonymousClipsWatched)
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
    
    /// Reset all local quota state (used for account deletion)
    func resetAll() {
        anonymousClipsWatched = 0
        defaults.removeObject(forKey: Keys.anonymousClipsWatched)
        defaults.removeObject(forKey: Keys.cachedProStatus)
        isProUser = false
        debugPrintStatus()
    }
    
    /// Returns the gate type to show for the current anonymous state.
    func gateTypeForAnonymousUser() -> ClipGateType? {
        EntitlementPolicy.gate(tier: .anonymous, clipsWatched: anonymousClipsWatched)
    }
    
    // MARK: - RevenueCat Pro Status
    
    /// Returns true if the RevenueCat Pro entitlement is active.
    @discardableResult
    func checkIsProUser() async -> Bool {
        do {
            let info = try await Purchases.shared.customerInfo()
            let isPro = info.entitlements[AppConstants.RevenueCat.proEntitlementID]?.isActive == true

            updateProStatus(isPro)
            return isPro
        } catch {
            Logger.warning("[ClipQuota] Failed to fetch RevenueCat customer info (possibly offline): \(error.localizedDescription)")
            Logger.debug("[ClipQuota] Using cached PRO status: \(isProUser)")
            // Return cached value - RevenueCat SDK also caches customer info
            return isProUser
        }
    }
    
    // MARK: - Private Helpers
    
    /// Observes RevenueCat customer info stream for subscription status changes
    private func observeRevenueCatCustomerInfo() {
        customerInfoStreamTask?.cancel()
        customerInfoStreamTask = Task { [weak self] in
            var isFirstEmission = true
            for await info in Purchases.shared.customerInfoStream {
                let isPro = info.entitlements[AppConstants.RevenueCat.proEntitlementID]?.isActive == true
                await MainActor.run {
                    guard let self = self else { return }

                    // On first emission, only update if we have no cached value
                    // This prevents RevenueCat's initial cached value from overriding our UserDefaults cache
                    if isFirstEmission {
                        isFirstEmission = false
                        if defaults.object(forKey: Keys.cachedProStatus) == nil {
                            Logger.debug("[ClipQuota] First RevenueCat emission, no cache: \(isPro)")
                            self.updateProStatus(isPro)
                        } else {
                            Logger.debug("[ClipQuota] First RevenueCat emission ignored, using cached: \(self.isProUser)")
                        }
                    } else {
                        // Subsequent emissions are actual updates
                        Logger.debug("[ClipQuota] RevenueCat update: \(isPro)")
                        self.updateProStatus(isPro)
                    }
                }
            }
        }
    }
    
    /// Updates Pro status and triggers appropriate actions on status change
    private func updateProStatus(_ newValue: Bool) {
        guard isProUser != newValue else { return }

        let wasProBefore = isProUser
        isProUser = newValue

        // Cache PRO status for offline mode
        defaults.set(newValue, forKey: Keys.cachedProStatus)
        Logger.debug("[ClipQuota] Cached PRO status for offline access: \(newValue)")
        
        if !newValue && wasProBefore {
            // Downgraded from Pro to Free
            Logger.debug("[ClipQuota] Subscription expired - downgrading to Free")
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
            Logger.info("[ClipQuota] Subscription activated")
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
            
            Logger.debug("[ClipQuota] Pro status synced to database: \(isProUser)")
        } catch {
            Logger.warning("[ClipQuota] Failed to sync Pro status: \(error)")
        }
    }
    
    /// Debug logging of current quota state
    private func debugPrintStatus() {
        Logger.debug("[ClipQuota] Anonymous clips watched: \(anonymousClipsWatched)/\(anonymousLimit)")
        Logger.debug("[ClipQuota] Pro status: \(isProUser ? "ACTIVE" : "inactive")")
    }
}

// MARK: - Gate Types

/// Possible gates to show after exhausting clip limits.
enum ClipGateType {
    case accountCreation    // Show "create account" gate (anonymous users)
    case proPaywall         // Show Pro paywall (logged-in free users)
}
