import Foundation

/// The complete event catalog — the single place where event names and properties are defined.
///
/// Two families coexist:
/// - **Legacy names** (`app_open`, `login`, `paywall_*`, …) kept byte-identical to what the 2.x
///   builds send, so historical charts don't break where they matter.
/// - **New `object_action` names** (`media_rated`, `episode_marked_watched`, …) for the flows the
///   old taxonomy never covered. Every event carries the `schema_version = 3` super property.
///
/// Adding an event = adding a case here. Raw `logEvent("name", …)` calls are what produced the
/// `onboarding_complete` vs `onboarding_completed` split — don't reintroduce them.
enum AnalyticsEvent {

    // MARK: Lifecycle & auth (legacy names)

    case appFirstOpen(installId: String)
    case appOpen(installId: String)
    case signUp(method: String)
    case login(method: String)

    // MARK: Onboarding

    case onboardingStarted
    case onboardingStepViewed(stepName: String, stepIndex: Int)
    /// Canonical name: the old builds sent the divergent `onboarding_complete`.
    case onboardingCompleted
    case onboardingSkipped(stepName: String)

    // MARK: Search & discovery

    case searchPerformed(query: String, resultCount: Int, source: String)
    case searchResultSelected(query: String, mediaId: Int, mediaType: String, position: Int, resultCount: Int?)
    case filterApplied(filterType: String, value: String, extra: [String: Any]?)
    case mediaDetailViewed(mediaType: String, mediaId: Int, title: String)

    // MARK: Rating, reviews & diary

    case mediaRated(mediaType: String, mediaId: Int, rating: Double, previousRating: Double?)
    case mediaRatingRemoved(mediaType: String, mediaId: Int)
    case reviewAdded(mediaType: String, mediaId: Int, containsSpoilers: Bool, textLength: Int)
    case reviewDeleted(mediaType: String, mediaId: Int)
    case diaryEntryAdded(mediaType: String, mediaId: Int, daysAgo: Int)
    case mediaFavorited(mediaType: String, mediaId: Int, added: Bool)

    // MARK: TV tracking

    case episodeMarkedWatched(showId: Int, seasonNumber: Int, episodeNumber: Int, method: String)
    case episodeMarkedUnwatched(showId: Int, seasonNumber: Int, episodeNumber: Int)
    case showMarkedWatched(showId: Int, episodesCount: Int)
    case showTrackingStarted(showId: Int)

    // MARK: Lists (legacy names)

    case listCreated(listType: String, listName: String)
    case listDeleted(listType: String)
    case addToWishlist(listType: String, mediaType: String)
    case reactionAdded(properties: [String: Any])
    case reactionRemoved(properties: [String: Any])

    // MARK: Social

    case feedCardOpened(activityType: String, position: Int?)
    case activityLiked(activityType: String, added: Bool)
    case activityCommentAdded(activityType: String)
    case activityHidden(activityType: String)
    case userFollowed(source: String)
    case userUnfollowed(source: String)
    case communityListOpened(listId: String)

    // MARK: Sharing

    case shareStarted(contentType: String, mediaType: String?)
    case shareCompleted(contentType: String, destination: String, success: Bool)

    // MARK: Import

    case importStarted(source: String)
    case importCompleted(itemsImported: Int, itemsFailed: Int)
    case importFailed(errorType: String, stage: String)

    // MARK: AI

    case aiChatMessageSent(queryType: String?, conversationLength: Int)
    case aiRecommendationOpened(position: Int, mediaType: String?, mediaId: Int?)

    // MARK: Notifications & deep links

    case notificationOpened(notificationType: String?)
    case deepLinkOpened(route: String, source: String)

    // MARK: Monetization (legacy names)

    case paywallViewed(source: String, type: String)
    case paywallDismissed(source: String, action: String)
    case paywallCTAClicked(source: String, cta: String)
    case paywallAutoTriggered(source: String)
    case purchaseStarted(properties: [String: Any])
    case purchase(productId: String, price: Double, currency: String)
    case purchaseFailed(properties: [String: Any])
    case trialStarted(productId: String, price: Double, currency: String)
    case restoreStarted(properties: [String: Any])
    case restoreSucceeded(properties: [String: Any])
    case restoreFailed(properties: [String: Any])
    case restoreNoActiveSubscription(properties: [String: Any])
    case subscriptionActivated
    case subscriptionExpired

    // MARK: Clips & gamification (legacy names)

    case clipImpression(properties: [String: Any])
    case clipCompletion(properties: [String: Any])
    case xpEarned(actionType: String, baseXP: Int, multiplier: Double, streakBonus: Double, totalXP: Int)
    case levelUp(oldLevel: Int, newLevel: Int, rankName: String)
    case badgeUnlocked(badgeId: String, badgeName: String, category: String)
    case dailyChallengeCompleted(challengeType: String, xpReward: Int)

    // MARK: Misc (legacy names)

    case languageChanged(from: String, to: String)
    case screenView(screenName: String, screenClass: String?)
    /// Marker emitted when the conditional session replay starts recording.
    case replayStarted(trigger: String)

    /// Escape hatch for events fired inline by legacy code paths not yet migrated to a typed
    /// case (e.g. ClipCommentService). New instrumentation must use a dedicated case instead.
    case legacy(name: String, properties: [String: Any]?)

    // MARK: - Wire format

    var name: String {
        switch self {
        case .appFirstOpen: return "app_first_open"
        case .appOpen: return "app_open"
        case .signUp: return "sign_up"
        case .login: return "login"
        case .onboardingStarted: return "onboarding_started"
        case .onboardingStepViewed: return "onboarding_step_viewed"
        case .onboardingCompleted: return "onboarding_completed"
        case .onboardingSkipped: return "onboarding_skipped"
        case .searchPerformed: return "search_performed"
        case .searchResultSelected: return "search_result_selected"
        case .filterApplied: return "filter_applied"
        case .mediaDetailViewed: return "media_detail_viewed"
        case .mediaRated: return "media_rated"
        case .mediaRatingRemoved: return "media_rating_removed"
        case .reviewAdded: return "review_added"
        case .reviewDeleted: return "review_deleted"
        case .diaryEntryAdded: return "diary_entry_added"
        case .mediaFavorited: return "media_favorited"
        case .episodeMarkedWatched: return "episode_marked_watched"
        case .episodeMarkedUnwatched: return "episode_marked_unwatched"
        case .showMarkedWatched: return "show_marked_watched"
        case .showTrackingStarted: return "show_tracking_started"
        case .listCreated: return "list_created"
        case .listDeleted: return "list_deleted"
        case .addToWishlist: return "add_to_wishlist"
        case .reactionAdded: return "reaction_added"
        case .reactionRemoved: return "reaction_removed"
        case .feedCardOpened: return "feed_card_opened"
        case .activityLiked: return "activity_liked"
        case .activityCommentAdded: return "activity_comment_added"
        case .activityHidden: return "activity_hidden"
        case .userFollowed: return "user_followed"
        case .userUnfollowed: return "user_unfollowed"
        case .communityListOpened: return "community_list_opened"
        case .shareStarted: return "share_started"
        case .shareCompleted: return "share_completed"
        case .importStarted: return "import_started"
        case .importCompleted: return "import_completed"
        case .importFailed: return "import_failed"
        case .aiChatMessageSent: return "ai_chat_message_sent"
        case .aiRecommendationOpened: return "ai_recommendation_opened"
        case .notificationOpened: return "notification_opened"
        case .deepLinkOpened: return "deep_link_opened"
        case .paywallViewed: return "paywall_viewed"
        case .paywallDismissed: return "paywall_dismissed"
        case .paywallCTAClicked: return "paywall_cta_clicked"
        case .paywallAutoTriggered: return "paywall_auto_triggered"
        case .purchaseStarted: return "purchase_started"
        case .purchase: return "purchase"
        case .purchaseFailed: return "purchase_failed"
        case .trialStarted: return "trial_started"
        case .restoreStarted: return "restore_started"
        case .restoreSucceeded: return "restore_succeeded"
        case .restoreFailed: return "restore_failed"
        case .restoreNoActiveSubscription: return "restore_no_active_subscription"
        case .subscriptionActivated: return "subscription_activated"
        case .subscriptionExpired: return "subscription_expired"
        case .clipImpression: return "clip_impression"
        case .clipCompletion: return "clip_completion"
        case .xpEarned: return "xp_earned"
        case .levelUp: return "level_up"
        case .badgeUnlocked: return "badge_unlocked"
        case .dailyChallengeCompleted: return "daily_challenge_completed"
        case .languageChanged: return "language_changed"
        case .screenView: return "screen_view"
        case .replayStarted: return "replay_started"
        case .legacy(let name, _): return name
        }
    }

    var properties: [String: Any] {
        switch self {
        case .appFirstOpen(let installId), .appOpen(let installId):
            return ["install_id": installId]
        case .signUp(let method), .login(let method):
            return ["method": method]
        case .onboardingStarted, .onboardingCompleted, .subscriptionActivated, .subscriptionExpired:
            return [:]
        case .onboardingStepViewed(let stepName, let stepIndex):
            return ["step_name": stepName, "step_index": stepIndex]
        case .onboardingSkipped(let stepName):
            return ["step_name": stepName]
        case .searchPerformed(let query, let resultCount, let source):
            return [
                "query": query,
                "query_length": query.count,
                "result_count": resultCount,
                "source": source,
            ]
        case .searchResultSelected(let query, let mediaId, let mediaType, let position, let resultCount):
            var props: [String: Any] = [
                "query": query,
                "media_id": mediaId,
                "media_type": mediaType,
                "position": position,
            ]
            if let resultCount { props["result_count"] = resultCount }
            return props
        case .filterApplied(let filterType, let value, let extra):
            var props: [String: Any] = ["filter_type": filterType, "value": value]
            if let extra { props.merge(extra) { current, _ in current } }
            return props
        case .mediaDetailViewed(let mediaType, let mediaId, let title):
            return ["media_type": mediaType, "media_id": mediaId, "title": title]
        case .mediaRated(let mediaType, let mediaId, let rating, let previousRating):
            var props: [String: Any] = ["media_type": mediaType, "media_id": mediaId, "rating": rating]
            if let previousRating { props["previous_rating"] = previousRating }
            return props
        case .mediaRatingRemoved(let mediaType, let mediaId):
            return ["media_type": mediaType, "media_id": mediaId]
        case .reviewAdded(let mediaType, let mediaId, let containsSpoilers, let textLength):
            return [
                "media_type": mediaType,
                "media_id": mediaId,
                "contains_spoilers": containsSpoilers,
                "text_length": textLength,
            ]
        case .reviewDeleted(let mediaType, let mediaId):
            return ["media_type": mediaType, "media_id": mediaId]
        case .diaryEntryAdded(let mediaType, let mediaId, let daysAgo):
            return ["media_type": mediaType, "media_id": mediaId, "days_ago": daysAgo]
        case .mediaFavorited(let mediaType, let mediaId, let added):
            return ["media_type": mediaType, "media_id": mediaId, "added": added]
        case .episodeMarkedWatched(let showId, let seasonNumber, let episodeNumber, let method):
            return [
                "show_id": showId,
                "season_number": seasonNumber,
                "episode_number": episodeNumber,
                "method": method,
            ]
        case .episodeMarkedUnwatched(let showId, let seasonNumber, let episodeNumber):
            return ["show_id": showId, "season_number": seasonNumber, "episode_number": episodeNumber]
        case .showMarkedWatched(let showId, let episodesCount):
            return ["show_id": showId, "episodes_count": episodesCount]
        case .showTrackingStarted(let showId):
            return ["show_id": showId]
        case .listCreated(let listType, let listName):
            return ["list_type": listType, "list_name": listName]
        case .listDeleted(let listType):
            return ["list_type": listType]
        case .addToWishlist(let listType, let mediaType):
            return ["list_type": listType, "media_type": mediaType]
        case .reactionAdded(let properties), .reactionRemoved(let properties):
            return properties
        case .feedCardOpened(let activityType, let position):
            var props: [String: Any] = ["activity_type": activityType]
            if let position { props["position"] = position }
            return props
        case .activityLiked(let activityType, let added):
            return ["activity_type": activityType, "added": added]
        case .activityCommentAdded(let activityType), .activityHidden(let activityType):
            return ["activity_type": activityType]
        case .userFollowed(let source), .userUnfollowed(let source):
            return ["source": source]
        case .communityListOpened(let listId):
            return ["list_id": listId]
        case .shareStarted(let contentType, let mediaType):
            var props: [String: Any] = ["content_type": contentType]
            if let mediaType { props["media_type"] = mediaType }
            return props
        case .shareCompleted(let contentType, let destination, let success):
            return ["content_type": contentType, "destination": destination, "success": success]
        case .importStarted(let source):
            return ["source": source]
        case .importCompleted(let itemsImported, let itemsFailed):
            return ["items_imported": itemsImported, "items_failed": itemsFailed]
        case .importFailed(let errorType, let stage):
            return ["error_type": errorType, "stage": stage]
        case .aiChatMessageSent(let queryType, let conversationLength):
            var props: [String: Any] = ["conversation_length": conversationLength]
            if let queryType { props["query_type"] = queryType }
            return props
        case .aiRecommendationOpened(let position, let mediaType, let mediaId):
            var props: [String: Any] = ["position": position]
            if let mediaType { props["media_type"] = mediaType }
            if let mediaId { props["media_id"] = mediaId }
            return props
        case .notificationOpened(let notificationType):
            var props: [String: Any] = [:]
            if let notificationType { props["notification_type"] = notificationType }
            return props
        case .deepLinkOpened(let route, let source):
            return ["route": route, "source": source]
        case .paywallViewed(let source, let type):
            return ["source": source, "type": type]
        case .paywallDismissed(let source, let action):
            return ["source": source, "action": action]
        case .paywallCTAClicked(let source, let cta):
            return ["source": source, "cta": cta]
        case .paywallAutoTriggered(let source):
            return ["source": source]
        case .purchase(let productId, let price, let currency),
             .trialStarted(let productId, let price, let currency):
            return ["product_id": productId, "price": price, "currency": currency]
        case .purchaseStarted(let properties), .purchaseFailed(let properties),
             .restoreStarted(let properties), .restoreSucceeded(let properties),
             .restoreFailed(let properties), .restoreNoActiveSubscription(let properties),
             .clipImpression(let properties), .clipCompletion(let properties):
            return properties
        case .xpEarned(let actionType, let baseXP, let multiplier, let streakBonus, let totalXP):
            return [
                "action_type": actionType,
                "base_xp": baseXP,
                "multiplier": multiplier,
                "streak_bonus": streakBonus,
                "total_xp": totalXP,
            ]
        case .levelUp(let oldLevel, let newLevel, let rankName):
            return ["old_level": oldLevel, "new_level": newLevel, "rank_name": rankName]
        case .badgeUnlocked(let badgeId, let badgeName, let category):
            return ["badge_id": badgeId, "badge_name": badgeName, "category": category]
        case .dailyChallengeCompleted(let challengeType, let xpReward):
            return ["challenge_type": challengeType, "xp_reward": xpReward]
        case .languageChanged(let from, let to):
            return ["from": from, "to": to]
        case .screenView(let screenName, let screenClass):
            return ["screen_name": screenName, "screen_class": screenClass ?? screenName]
        case .replayStarted(let trigger):
            return ["trigger": trigger]
        case .legacy(_, let properties):
            return properties ?? [:]
        }
    }

    /// The core actions worth watching in session replay. Kept next to the catalog so a new
    /// event's replay behaviour is decided where the event is defined.
    var replayTrigger: String? {
        switch self {
        case .mediaRated: return "media_rated"
        case .addToWishlist: return "add_to_wishlist"
        case .listCreated: return "list_created"
        case .searchResultSelected: return "search_result_selected"
        case .activityLiked: return "activity_liked"
        case .activityCommentAdded: return "activity_comment_added"
        case .userFollowed: return "user_followed"
        case .shareStarted: return "share_started"
        case .importStarted: return "import_started"
        default: return nil
        }
    }
}
