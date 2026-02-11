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

        Logger.info("[Analytics] Service initialized (enabled=\(isEnabled))")

        // Log diagnostics on startup to help debug production issues
        logDiagnostics()
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
                Logger.info("[Analytics] Identifying user in PostHog: \(userId) (anonymous: \(installId))")
                Task.detached {
                    await PostHogClient.shared.identify(
                        newDistinctId: userId,
                        anonymousDistinctId: InstallIDService.getOrCreateInstallId()
                    )
                    Logger.info("[Analytics] User identification event sent to PostHog")
                }
            } else {
                Logger.info("[Analytics] User \(userId) already identified, skipping PostHog identify call")
            }
        }

        if let userId = userId {
            Logger.info("[Analytics] User ID set: \(userId)")
        } else {
            Logger.info("[Analytics] User ID cleared (anonymous mode)")
        }
    }
    
    /// Set user properties
    func setUserProperty(_ value: String?, forName name: String) {
        #if canImport(FirebaseAnalytics)
        Analytics.setUserProperty(value, forName: name)
        #endif
        
        Logger.debug("[Analytics] User property set: \(name) = \(value ?? "nil")")
    }
    
    /// Enable/disable analytics
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.isEnabled)
        
        #if canImport(FirebaseAnalytics)
        Analytics.setAnalyticsCollectionEnabled(enabled)
        #endif
        
        Logger.debug("[Analytics] \(enabled ? "Enabled" : "Disabled")")
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

    /// Clip impression
    func logClipImpression(clip: Clip, context: AnalyticsContext? = nil) {
        var params: [String: Any] = [
            "clip_id": clip.id,
            "video_id": clip.videoId,
            "duration_seconds": clip.duration,
            "media_type": clip.inferredMediaType.rawValue,
            "is_segment": clip.isSegment
        ]

        if let mediaId = clip.movieId ?? clip.tvShowId {
            params["media_id"] = mediaId
        }

        if let originalClipId = clip.originalClipId {
            params["original_clip_id"] = originalClipId
        }

        if let segmentIndex = clip.segmentIndex {
            params["segment_index"] = segmentIndex
        }

        logEventWithContext("clip_impression", parameters: params, context: context)
    }

    /// Clip completion metrics
    func logClipCompletion(clip: Clip, watchedSeconds: Double, context: AnalyticsContext? = nil) {
        let totalSeconds = Double(max(clip.duration, 0))
        let completionRatio = AnalyticsContext.completionRatio(watched: watchedSeconds, total: totalSeconds)
        var params: [String: Any] = [
            "clip_id": clip.id,
            "video_id": clip.videoId,
            "media_type": clip.inferredMediaType.rawValue,
            "watched_seconds": watchedSeconds,
            "total_seconds": totalSeconds,
            "completion_ratio": completionRatio
        ]

        if let mediaId = clip.movieId ?? clip.tvShowId {
            params["media_id"] = mediaId
        }

        logEventWithContext("clip_completion", parameters: params, context: context)
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
    func logItemAddedToList(
        listType: String,
        mediaType: String,
        context: AnalyticsContext? = nil
    ) {
        logEventWithContext(
            "add_to_wishlist",
            parameters: [
                "list_type": listType,
                "media_type": mediaType
            ],
            context: context
        )
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
    func logFilterApplied(
        filterType: String,
        value: String,
        context: AnalyticsContext? = nil,
        extra: [String: Any]? = nil
    ) {
        var params: [String: Any] = [
            "filter_type": filterType, // "genre", "country", "duration", etc.
            "value": value
        ]

        if let extra {
            for (key, value) in extra {
                params[key] = value
            }
        }

        logEventWithContext("filter_applied", parameters: params, context: context)
    }

    func logSearchResultSelected(
        query: String,
        mediaId: Int,
        mediaType: String,
        position: Int,
        resultCount: Int?,
        context: AnalyticsContext? = nil
    ) {
        var params: [String: Any] = [
            "query": query,
            "media_id": mediaId,
            "media_type": mediaType,
            "position": position
        ]

        if let resultCount {
            params["result_count"] = resultCount
        }

        logEventWithContext("search_result_selected", parameters: params, context: context)
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

    // MARK: - Social & Engagement Events

    /// Content shared
    func logShareContent(mediaId: Int, mediaType: String, shareDestination: String) {
        logEvent("share_content", parameters: [
            "media_id": mediaId,
            "media_type": mediaType,
            "share_destination": shareDestination
        ])
    }

    /// Comment posted
    func logCommentPosted(clipId: String, mediaId: Int?, isReply: Bool) {
        var params: [String: Any] = [
            "clip_id": clipId,
            "is_reply": isReply
        ]
        if let mediaId = mediaId {
            params["media_id"] = mediaId
        }
        logEvent("comment_posted", parameters: params)
    }

    /// Clip liked/unliked
    func logClipReaction(clipId: String, mediaId: Int?, reactionType: String, added: Bool) {
        var params: [String: Any] = [
            "clip_id": clipId,
            "reaction_type": reactionType,
            "added": added
        ]
        if let mediaId = mediaId {
            params["media_id"] = mediaId
        }
        logEvent("clip_reaction", parameters: params)
    }

    // MARK: - Gamification Events

    /// XP earned event
    func logXPEarned(actionType: String, baseXP: Int, multiplier: Double, streakBonus: Double, totalXP: Int) {
        logEvent("xp_earned", parameters: [
            "action_type": actionType,
            "base_xp": baseXP,
            "multiplier": multiplier,
            "streak_bonus": streakBonus,
            "total_xp": totalXP
        ])
    }

    /// Level up event
    func logLevelUp(oldLevel: Int, newLevel: Int, rankName: String) {
        logEvent("level_up", parameters: [
            "old_level": oldLevel,
            "new_level": newLevel,
            "rank_name": rankName
        ])
    }

    /// Badge unlocked
    func logBadgeUnlocked(badgeId: String, badgeName: String, category: String) {
        logEvent("badge_unlocked", parameters: [
            "badge_id": badgeId,
            "badge_name": badgeName,
            "category": category
        ])
    }

    /// Streak milestone
    func logStreakMilestone(streakDays: Int, bonusPercentage: Int) {
        logEvent("streak_milestone", parameters: [
            "streak_days": streakDays,
            "bonus_percentage": bonusPercentage
        ])
    }

    /// Daily challenge completed
    func logDailyChallengeCompleted(challengeType: String, xpReward: Int) {
        logEvent("daily_challenge_completed", parameters: [
            "challenge_type": challengeType,
            "xp_reward": xpReward
        ])
    }

    // MARK: - Diagnostics

    /// Log analytics status for debugging production issues
    func logDiagnostics() {
        Logger.info("[Analytics] Status check:")
        Logger.info("[Analytics]   - Enabled: \(isEnabled)")
        Logger.info("[Analytics]   - User ID: \(userId ?? "anonymous")")
        Logger.info("[Analytics]   - Install ID: \(installId)")
        Logger.info("[Analytics]   - PostHog API Key present: \(!Config.posthogApiKey.isEmpty)")
        Logger.info("[Analytics]   - PostHog Host: \(Config.posthogHost.isEmpty ? "MISSING" : Config.posthogHost)")

        Task {
            let diagnostics = await PostHogClient.shared.diagnostics()
            await MainActor.run {
                Logger.info("[Analytics]   - PostHog queue count: \(diagnostics.queueCount)")
                Logger.info("[Analytics]   - PostHog is flushing: \(diagnostics.isFlushing)")
                Logger.info("[Analytics]   - PostHog flush attempts: \(diagnostics.flushAttemptCount)")
                if let lastError = diagnostics.lastFlushErrorDescription {
                    Logger.error("[Analytics]   - PostHog last error: \(lastError)")
                }
            }
        }
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

        Logger.debug("[Analytics] Event: \(name) \(parameters != nil ? "with params" : "")")
    }

    func logEventWithContext(
        _ name: String,
        parameters: [String: Any]?,
        context: AnalyticsContext?
    ) {
        logEvent(name, parameters: mergedParameters(parameters, context: context))
    }

    private func mergedParameters(
        _ parameters: [String: Any]?,
        context: AnalyticsContext?
    ) -> [String: Any]? {
        guard let context else { return parameters }
        var merged = parameters ?? [:]
        for (key, value) in context.properties() {
            merged[key] = value
        }
        return merged.isEmpty ? nil : merged
    }

    private func captureToPostHog(name: String, parameters: [String: Any]?) async {
        let distinctId = userId ?? installId
        await PostHogClient.shared.capture(
            event: name,
            distinctId: distinctId,
            properties: parameters
        )
    }

    func recentEvents(limit: Int) -> [EventSnapshot] {
        events.suffix(limit).map { EventSnapshot(name: $0.name, parameters: $0.parameters, timestamp: $0.timestamp) }
    }
}
