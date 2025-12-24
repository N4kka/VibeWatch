import Foundation
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif

/// Centralized analytics tracking service
/// Tracks key user events for product insights
@MainActor
class AnalyticsService {
    static let shared = AnalyticsService()

    struct EventSnapshot: Identifiable {
        let id = UUID()
        let name: String
        let parameters: [String: Any]?
        let timestamp: Date
    }
    
    private var isEnabled: Bool
    private var userId: String?
    private var events: [(name: String, parameters: [String: Any]?, timestamp: Date)] = []
    private let installId: String
    private var pendingUserProperties: [String: String] = [:]
    private var pendingUnsetUserProperties: Set<String> = []

    private enum DefaultsKeys {
        static let isEnabled = "analytics.isEnabled"
        static let firstOpenTracked = "analytics.firstOpenTracked"
        static let lastIdentifiedUserId = "analytics.lastIdentifiedUserId"
    }
    
    private init() {
        self.installId = InstallIDService.getOrCreateInstallId()

        if UserDefaults.standard.object(forKey: DefaultsKeys.isEnabled) == nil {
            UserDefaults.standard.set(true, forKey: DefaultsKeys.isEnabled)
        }
        self.isEnabled = UserDefaults.standard.bool(forKey: DefaultsKeys.isEnabled)

        print("📊 [Analytics] Service initialized (enabled=\(isEnabled))")
    }
    
    /// Set user ID for analytics
    func setUserId(_ userId: String?) {
        let previousUserId = self.userId
        self.userId = userId
        
        #if canImport(FirebaseAnalytics)
        Analytics.setUserID(userId)
        #endif

        if let userId, userId != previousUserId {
            let lastIdentified = UserDefaults.standard.string(forKey: DefaultsKeys.lastIdentifiedUserId)
            if lastIdentified != userId {
                UserDefaults.standard.set(userId, forKey: DefaultsKeys.lastIdentifiedUserId)
                Task.detached {
                    await PostHogClient.shared.identify(
                        newDistinctId: userId,
                        anonymousDistinctId: InstallIDService.getOrCreateInstallId()
                    )
                }
            }
        }
        
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

        if let value {
            pendingUserProperties[name] = value
            pendingUnsetUserProperties.remove(name)
        } else {
            pendingUserProperties.removeValue(forKey: name)
            pendingUnsetUserProperties.insert(name)
        }
        
        print("📊 [Analytics] User property set: \(name) = \(value ?? "nil")")
    }
    
    /// Enable/disable analytics
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.isEnabled)
        
        #if canImport(FirebaseAnalytics)
        Analytics.setAnalyticsCollectionEnabled(enabled)
        #endif
        
        print("📊 [Analytics] \(enabled ? "Enabled" : "Disabled")")
    }

    func recentEvents(limit: Int = 50) -> [EventSnapshot] {
        let slice = events.suffix(limit)
        return slice.map { EventSnapshot(name: $0.name, parameters: $0.parameters, timestamp: $0.timestamp) }
    }

    // MARK: - Event Tracking

    func trackAppOpen() {
        guard isEnabled else { return }

        var eventsToCapture: [(name: String, parameters: [String: Any]?)] = []

        if !UserDefaults.standard.bool(forKey: DefaultsKeys.firstOpenTracked) {
            UserDefaults.standard.set(true, forKey: DefaultsKeys.firstOpenTracked)
            let params: [String: Any] = [
                "install_id": installId
            ]
            logEventLocal("app_first_open", parameters: params)
            eventsToCapture.append((name: "app_first_open", parameters: params))
        }

        let openParams: [String: Any] = [
            "install_id": installId
        ]
        logEventLocal("app_open", parameters: openParams)
        eventsToCapture.append((name: "app_open", parameters: openParams))

        Task {
            for event in eventsToCapture {
                await captureToPostHog(name: event.name, parameters: event.parameters)
            }
            try? await PostHogClient.shared.flush()
        }
    }
    
    /// Track generic event
    func logEvent(_ name: String, parameters: [String: Any]? = nil) {
        guard isEnabled else { return }

        logEventLocal(name, parameters: parameters)

        Task {
            await captureToPostHog(name: name, parameters: parameters)
        }
    }
    
    // MARK: - Authentication Events
    
    /// User created account
    func logAccountCreated(method: String) {
        setUserProperty(method, forName: "signup_method")
        #if canImport(FirebaseAnalytics)
        logEvent(AnalyticsEventSignUp, parameters: [
            AnalyticsParameterMethod: method // "email", "apple", "google"
        ])
        #else
        logEvent("sign_up", parameters: [
            "method": method
        ])
        #endif
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
        setUserProperty("true", forName: "has_trial")
        logEvent("trial_started", parameters: [
            "product_id": productId,
            "price": price,
            "currency": currency
        ])
    }
    
    /// Subscription purchased
    func logSubscriptionPurchased(
        productId: String,
        price: Double,
        currency: String = "EUR",
        isFoundingMember: Bool
    ) {
        setUserProperty("pro", forName: "subscription_tier")
        if isFoundingMember {
            setUserProperty("true", forName: "is_founding_member")
        }

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
    }
    
    /// Subscription canceled
    func logSubscriptionCanceled(productId: String, reason: String? = nil) {
        setUserProperty("canceled", forName: "subscription_tier")
        var params: [String: Any] = ["product_id": productId]
        if let reason = reason {
            params["reason"] = reason
        }
        
        logEvent("subscription_canceled", parameters: params)
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
        setUserProperty(to, forName: "preferred_language")
        logEvent("language_changed", parameters: [
            "from": from,
            "to": to
        ])
    }
    
    // MARK: - Onboarding
    
    /// Onboarding started
    func logOnboardingStarted() {
        logEvent("onboarding_started", parameters: nil)
    }
    
    /// Onboarding completed
    func logOnboardingCompleted() {
        setUserProperty("true", forName: "onboarding_completed")
        logEvent("onboarding_completed", parameters: nil)
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

    // MARK: - Internal Helpers

    private func logEventLocal(_ name: String, parameters: [String: Any]?) {
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

    private func captureToPostHog(name: String, parameters: [String: Any]?) async {
        let distinctId = userId ?? installId
        var eventParameters = parameters ?? [:]
        if !pendingUnsetUserProperties.isEmpty {
            eventParameters["$unset"] = Array(pendingUnsetUserProperties)
        }
        await PostHogClient.shared.capture(
            event: name,
            distinctId: distinctId,
            userProperties: pendingUserProperties.isEmpty ? nil : pendingUserProperties,
            properties: eventParameters.isEmpty ? nil : eventParameters
        )
        pendingUserProperties.removeAll()
        pendingUnsetUserProperties.removeAll()
    }
}
