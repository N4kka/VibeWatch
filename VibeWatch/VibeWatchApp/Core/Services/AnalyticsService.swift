import Foundation
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif

/// Centralized analytics tracking service
/// Tracks key user events for product insights
@MainActor
class AnalyticsService {
    static let shared = AnalyticsService()
    
    private var isEnabled = false
    private var userId: String?
    private var events: [(name: String, parameters: [String: Any]?, timestamp: Date)] = []
    
    private init() {
        print("📊 [Analytics] Service initialized (disabled by default)")
    }
    
    /// Set user ID for analytics
    func setUserId(_ userId: String?) {
        self.userId = userId
        
        #if canImport(FirebaseAnalytics)
        Analytics.setUserID(userId)
        #endif
        
        if let userId = userId {
            print("📊 [Analytics] User ID set: \(userId)")
        } else {
            print("📊 [Analytics] User ID cleared")
        }
    }
    
    /// Set user properties
    func setUserProperty(_ value: String?, forName name: String) {
        #if canImport(FirebaseAnalytics)
        Analytics.setUserProperty(value, forName: name)
        #endif
        
        print("📊 [Analytics] User property set: \(name) = \(value ?? "nil")")
    }
    
    /// Enable/disable analytics
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        
        #if canImport(FirebaseAnalytics)
        Analytics.setAnalyticsCollectionEnabled(enabled)
        #endif
        
        print("📊 [Analytics] \(enabled ? "Enabled" : "Disabled")")
    }
    
    // MARK: - Event Tracking
    
    /// Track generic event
    func logEvent(_ name: String, parameters: [String: Any]? = nil) {
        guard isEnabled else { return }
        
        // Store locally for debugging
        events.append((name, parameters, Date()))
        if events.count > 100 {
            events.removeFirst()
        }
        
        #if canImport(FirebaseAnalytics)
        Analytics.logEvent(name, parameters: parameters)
        #endif
        
        print("📊 [Analytics] Event: \(name) \(parameters != nil ? "with params" : "")")
    }
    
    // MARK: - Authentication Events
    
    /// User created account
    func logAccountCreated(method: String) {
        #if canImport(FirebaseAnalytics)
        logEvent(AnalyticsEventSignUp, parameters: [
            AnalyticsParameterMethod: method // "email", "apple", "google"
        ])
        #else
        logEvent("sign_up", parameters: [
            "method": method
        ])
        #endif
        
        // Set user property
        setUserProperty(method, forName: "signup_method")
    }
    
    /// User signed in
    func logSignIn(method: String) {
        #if canImport(FirebaseAnalytics)
        logEvent(AnalyticsEventLogin, parameters: [
            AnalyticsParameterMethod: method
        ])
        #else
        logEvent("login", parameters: [
            "method": method
        ])
        #endif
    }
    
    // MARK: - Subscription Events
    
    /// Trial started
    func logTrialStarted(productId: String, price: Double, currency: String = "EUR") {
        logEvent("trial_started", parameters: [
            "product_id": productId,
            "price": price,
            "currency": currency
        ])
        
        setUserProperty("true", forName: "has_trial")
    }
    
    /// Subscription purchased
    func logSubscriptionPurchased(
        productId: String,
        price: Double,
        currency: String = "EUR",
        isFoundingMember: Bool
    ) {
        #if canImport(FirebaseAnalytics)
        logEvent(AnalyticsEventPurchase, parameters: [
            "product_id": productId,
            AnalyticsParameterPrice: price,
            AnalyticsParameterCurrency: currency,
            "is_founding_member": isFoundingMember
        ])
        #else
        logEvent("purchase", parameters: [
            "product_id": productId,
            "price": price,
            "currency": currency,
            "is_founding_member": isFoundingMember
        ])
        #endif
        
        setUserProperty("pro", forName: "subscription_tier")
        if isFoundingMember {
            setUserProperty("true", forName: "is_founding_member")
        }
    }
    
    /// Subscription canceled
    func logSubscriptionCanceled(productId: String, reason: String? = nil) {
        var params: [String: Any] = ["product_id": productId]
        if let reason = reason {
            params["reason"] = reason
        }
        
        logEvent("subscription_canceled", parameters: params)
        setUserProperty("canceled", forName: "subscription_tier")
    }
    
    /// Subscription renewed
    func logSubscriptionRenewed(productId: String, price: Double) {
        logEvent("subscription_renewed", parameters: [
            "product_id": productId,
            "price": price
        ])
    }
    
    /// Restore purchases
    func logPurchasesRestored(count: Int) {
        logEvent("purchases_restored", parameters: [
            "count": count
        ])
    }
    
    // MARK: - Content Events
    
    /// Clip viewed
    func logClipViewed(clipId: String, mediaId: Int, duration: Double) {
        logEvent("clip_viewed", parameters: [
            "clip_id": clipId,
            "media_id": mediaId,
            "duration": duration
        ])
    }
    
    /// Clip skipped
    func logClipSkipped(clipId: String, mediaId: Int, watchedDuration: Double) {
        logEvent("clip_skipped", parameters: [
            "clip_id": clipId,
            "media_id": mediaId,
            "watched_duration": watchedDuration
        ])
    }
    
    /// Movie/show viewed
    func logContentViewed(mediaId: Int, mediaType: String, title: String) {
        logEvent("view_item", parameters: [
            "media_id": mediaId,
            "media_type": mediaType,
            "title": title
        ])
    }
    
    /// Search performed
    func logSearch(query: String, resultCount: Int) {
        logEvent("search", parameters: [
            "search_term": query,
            "result_count": resultCount
        ])
    }
    
    // MARK: - List Events
    
    /// List created
    func logListCreated(listType: String, listName: String) {
        logEvent("list_created", parameters: [
            "list_type": listType, // "custom", "watchlist", etc.
            "list_name": listName
        ])
    }
    
    /// List deleted
    func logListDeleted(listType: String) {
        logEvent("list_deleted", parameters: [
            "list_type": listType
        ])
    }
    
    /// Item added to list
    func logItemAddedToList(listType: String, mediaType: String) {
        logEvent("add_to_wishlist", parameters: [
            "list_type": listType,
            "media_type": mediaType
        ])
    }
    
    /// Item removed from list
    func logItemRemovedFromList(listType: String, mediaType: String) {
        logEvent("item_removed_from_list", parameters: [
            "list_type": listType,
            "media_type": mediaType
        ])
    }
    
    // MARK: - Paywall Events
    
    /// Paywall viewed
    func logPaywallViewed(source: String, type: String) {
        logEvent("paywall_viewed", parameters: [
            "source": source, // "clips_limit", "account_gate", "list_limit", etc.
            "type": type // "daily_limit", "account_creation", "pro_features"
        ])
    }
    
    /// Paywall dismissed
    func logPaywallDismissed(source: String, action: String) {
        logEvent("paywall_dismissed", parameters: [
            "source": source,
            "action": action // "close", "come_back_tomorrow", etc.
        ])
    }
    
    /// CTA clicked on paywall
    func logPaywallCTAClicked(source: String, cta: String) {
        logEvent("paywall_cta_clicked", parameters: [
            "source": source,
            "cta": cta // "upgrade", "start_trial", "sign_up"
        ])
    }
    
    // MARK: - Feature Usage
    
    /// Filter applied
    func logFilterApplied(filterType: String, value: String) {
        logEvent("filter_applied", parameters: [
            "filter_type": filterType, // "genre", "country", "duration", etc.
            "value": value
        ])
    }
    
    /// Platform selected
    func logPlatformSelected(platform: String) {
        logEvent("platform_selected", parameters: [
            "platform": platform // "netflix", "disney", etc.
        ])
    }
    
    /// Language changed
    func logLanguageChanged(from: String, to: String) {
        logEvent("language_changed", parameters: [
            "from": from,
            "to": to
        ])
        
        setUserProperty(to, forName: "preferred_language")
    }
    
    // MARK: - Onboarding
    
    /// Onboarding started
    func logOnboardingStarted() {
        logEvent("onboarding_started", parameters: nil)
    }
    
    /// Onboarding completed
    func logOnboardingCompleted() {
        logEvent("onboarding_completed", parameters: nil)
        setUserProperty("true", forName: "onboarding_completed")
    }
    
    /// Onboarding skipped
    func logOnboardingSkipped(step: Int) {
        logEvent("onboarding_skipped", parameters: [
            "step": step
        ])
    }
    
    // MARK: - Error Tracking
    
    /// Log error for analytics
    func logError(_ error: AppError, context: String) {
        logEvent("error_occurred", parameters: [
            "error_type": String(describing: error),
            "error_message": error.localizedDescription,
            "context": context
        ])
    }
    
    // MARK: - Screen Tracking
    
    /// Track screen view
    func logScreenView(screenName: String, screenClass: String? = nil) {
        logEvent("screen_view", parameters: [
            "screen_name": screenName,
            "screen_class": screenClass ?? screenName
        ])
    }
}
