import Foundation

/// Centralized analytics facade.
///
/// Call sites talk to this class only; the actual delivery goes through `AnalyticsBackend`
/// (PostHog SDK in production, a spy in tests). Event names and properties live in one place —
/// the `AnalyticsEvent` catalog — so the taxonomy can't drift per call site.
///
/// Consent: `analytics.isEnabled` (default true, opt-out) is the single gate. It maps to the
/// SDK's own `optIn()/optOut()`, which also stops replay and exception capture. `setUserId` is
/// guarded too, so an opted-out user never produces an `$identify`.
@MainActor
class AnalyticsService {
    static let shared = AnalyticsService()

    struct EventSnapshot: Identifiable {
        let id = UUID()
        let name: String
        let parameters: [String: Any]?
        let timestamp: Date
    }

    struct Diagnostics {
        let isConfigured: Bool
        let isEnabled: Bool
        let distinctId: String?
        let isReplayActive: Bool
    }

    private(set) var isEnabled: Bool
    private var userId: String?
    private var events: [(name: String, parameters: [String: Any]?, timestamp: Date)] = []
    private let installId: String

    private(set) var backend: AnalyticsBackend?
    private(set) var replay: SessionReplayController

    private enum DefaultsKeys {
        static let isEnabled = "analytics.isEnabled"
        static let firstOpenTracked = "analytics.firstOpenTracked"
        // Chiavi dell'era PostHogClient fatto in casa, da ripulire sui device esistenti.
        static let legacyQueueV1 = "posthog.queue.v1"
        static let legacyQueueV2 = "posthog.queue.v2"
        static let legacyLastIdentifiedUserId = "analytics.lastIdentifiedUserId"
    }

    private init() {
        self.installId = InstallIDService.getOrCreateInstallId()

        if UserDefaults.standard.object(forKey: DefaultsKeys.isEnabled) == nil {
            UserDefaults.standard.set(true, forKey: DefaultsKeys.isEnabled)
        }
        self.isEnabled = UserDefaults.standard.bool(forKey: DefaultsKeys.isEnabled)
        self.replay = SessionReplayController(backend: nil)

        // The hand-rolled client's queue is not replayed into the SDK: at most 200 stale events
        // of the deprecated taxonomy, not worth the migration surface.
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.legacyQueueV1)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.legacyQueueV2)
        // Identify dedup is the SDK's job now.
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.legacyLastIdentifiedUserId)

        Logger.info("[Analytics] Service initialized (enabled=\(isEnabled))")
    }

    // MARK: - Bootstrap

    /// Call once from `AppDelegate.didFinishLaunchingWithOptions`, before anything can capture.
    /// Sets up the PostHog SDK, wires the replay controller, and swaps the crash reporter onto
    /// the same backend so events, errors and replays share one pipeline.
    static func bootstrap() {
        shared.bootstrapBackend()
    }

    private func bootstrapBackend() {
        guard backend == nil else { return }
        guard let realBackend = PostHogAnalyticsBackend.bootstrap(isEnabled: isEnabled, installId: installId) else {
            return
        }
        backend = realBackend
        replay = SessionReplayController(backend: realBackend)
        CrashReportingService.reporter = PostHogCrashReporter(backend: realBackend)
        logDiagnostics()
    }

    // MARK: - Identity & consent

    /// Identify the signed-in user (Supabase user id). Person properties carry the non-PII
    /// profile snapshot — no email by design.
    func setUserId(_ userId: String?, signedUpAt: Date? = nil) {
        self.userId = userId

        guard let userId else {
            Logger.info("[Analytics] User ID cleared (anonymous mode)")
            return
        }

        // Consent gate: an opted-out user must not produce an $identify (the SDK would ignore it
        // too, but the guard keeps intent explicit and the log honest).
        guard isEnabled else {
            Logger.info("[Analytics] Identify skipped (analytics disabled)")
            return
        }

        var setOnce: [String: Any] = [:]
        if let signedUpAt {
            setOnce["signed_up_at"] = ISO8601DateFormatter().string(from: signedUpAt)
        }
        backend?.identify(
            userId,
            userProperties: currentPersonProperties(),
            userPropertiesSetOnce: setOnce.isEmpty ? nil : setOnce
        )
        Logger.info("[Analytics] Identified user: \(userId)")
    }

    /// Sign-out: back to a fresh anonymous identity. `reset()` clears the SDK's distinct id,
    /// super properties and session — re-register what must survive.
    func reset() {
        userId = nil
        backend?.reset()
        backend?.register([
            "install_id": installId,
            "schema_version": PostHogAnalyticsBackend.schemaVersion,
        ])
        Logger.info("[Analytics] Reset to anonymous identity")
    }

    /// Update person properties for the identified user (no-op while anonymous or disabled).
    func setPersonProperties(_ properties: [String: Any]) {
        guard isEnabled, userId != nil, !properties.isEmpty else { return }
        backend?.capture("$set", properties: nil, userProperties: properties)
    }

    /// Enable/disable analytics. Single gate for events, replay, and error tracking.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.isEnabled)

        if enabled {
            backend?.optIn()
        } else {
            replay.stopIfActive()
            backend?.optOut()
        }

        // Kept for the CrashReporter abstraction; the PostHog reporter no-ops here because the
        // SDK opt-out above already covers exception capture.
        CrashReportingService.setCollectionEnabled(enabled)

        Logger.debug("[Analytics] \(enabled ? "Enabled" : "Disabled")")
    }

    private func currentPersonProperties() -> [String: Any] {
        var props: [String: Any] = [:]
        props["preferred_language"] = LocalizationManager.shared.currentLanguage.id
        if let region = Locale.current.region?.identifier {
            props["country"] = region
        }
        let onboardingCompleted = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        props["onboarding_completed"] = onboardingCompleted
        return props
    }

    // MARK: - Core tracking

    /// The only path to the wire: logs locally for the debug view, forwards to the backend, and
    /// starts session replay when the event is one of the core-action triggers.
    func track(_ event: AnalyticsEvent, context: AnalyticsContext? = nil) {
        guard isEnabled else { return }

        let properties = mergedParameters(event.properties, context: context)
        logEventLocal(event.name, parameters: properties)
        backend?.capture(event.name, properties: properties, userProperties: nil)

        if let trigger = event.replayTrigger {
            replay.trigger(.coreAction(trigger))
        }
    }

    /// Escape hatch for dynamic event names. Prefer `track(_:)` with a catalog case.
    func logEvent(_ name: String, parameters: [String: Any]? = nil) {
        track(.legacy(name: name, properties: parameters))
    }

    func logEventWithContext(
        _ name: String,
        parameters: [String: Any]?,
        context: AnalyticsContext?
    ) {
        track(.legacy(name: name, properties: parameters), context: context)
    }

    func trackAppOpen() {
        guard isEnabled else { return }

        if !UserDefaults.standard.bool(forKey: DefaultsKeys.firstOpenTracked) {
            // Il flag locale, non l'evento nativo "Application Installed": quello riscatterebbe
            // per tutti gli utenti esistenti al primo aggiornamento a questa versione.
            UserDefaults.standard.set(true, forKey: DefaultsKeys.firstOpenTracked)
            track(.appFirstOpen(installId: installId))
        }
        track(.appOpen(installId: installId))
    }

    // MARK: - Screen tracking

    /// Emits both the legacy `screen_view` (continuity with existing charts) and the native
    /// `$screen` (feeds PostHog screen analytics and replay timelines).
    func logScreenView(screenName: String, screenClass: String? = nil) {
        guard isEnabled else { return }
        track(.screenView(screenName: screenName, screenClass: screenClass))
        backend?.screen(screenName, properties: nil)
    }

    // MARK: - Typed helpers (existing call sites keep their signatures)

    func logAccountCreated(method: String) {
        track(.signUp(method: method))
        setPersonProperties(["login_provider": method])
    }

    func logSignIn(method: String) {
        track(.login(method: method))
    }

    func logTrialStarted(productId: String, price: Double, currency: String = "EUR") {
        track(.trialStarted(productId: productId, price: price, currency: currency))
    }

    func logSubscriptionPurchased(productId: String, price: Double, currency: String = "EUR") {
        track(.purchase(productId: productId, price: price, currency: currency))
        setPersonProperties(["subscription_tier": "pro"])
    }

    func logClipImpression(clip: Clip, context: AnalyticsContext? = nil) {
        var params: [String: Any] = [
            "clip_id": clip.id,
            "video_id": clip.videoId,
            "duration_seconds": clip.duration,
            "media_type": clip.inferredMediaType.rawValue,
            "is_segment": clip.isSegment,
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
        track(.clipImpression(properties: params), context: context)
    }

    func logClipCompletion(clip: Clip, watchedSeconds: Double, context: AnalyticsContext? = nil) {
        let totalSeconds = Double(max(clip.duration, 0))
        let completionRatio = AnalyticsContext.completionRatio(watched: watchedSeconds, total: totalSeconds)
        var params: [String: Any] = [
            "clip_id": clip.id,
            "video_id": clip.videoId,
            "media_type": clip.inferredMediaType.rawValue,
            "watched_seconds": watchedSeconds,
            "total_seconds": totalSeconds,
            "completion_ratio": completionRatio,
        ]
        if let mediaId = clip.movieId ?? clip.tvShowId {
            params["media_id"] = mediaId
        }
        track(.clipCompletion(properties: params), context: context)
    }

    func logListCreated(listType: String, listName: String) {
        track(.listCreated(listType: listType, listName: listName))
    }

    func logListDeleted(listType: String) {
        track(.listDeleted(listType: listType))
    }

    func logItemAddedToList(listType: String, mediaType: String, context: AnalyticsContext? = nil) {
        track(.addToWishlist(listType: listType, mediaType: mediaType), context: context)
    }

    func logPaywallViewed(source: String, type: String) {
        track(.paywallViewed(source: source, type: type))
    }

    func logPaywallDismissed(source: String, action: String) {
        track(.paywallDismissed(source: source, action: action))
    }

    func logPaywallCTAClicked(source: String, cta: String) {
        track(.paywallCTAClicked(source: source, cta: cta))
    }

    func logFilterApplied(
        filterType: String,
        value: String,
        context: AnalyticsContext? = nil,
        extra: [String: Any]? = nil
    ) {
        track(.filterApplied(filterType: filterType, value: value, extra: extra), context: context)
    }

    func logSearchResultSelected(
        query: String,
        mediaId: Int,
        mediaType: String,
        position: Int,
        resultCount: Int?,
        context: AnalyticsContext? = nil
    ) {
        track(
            .searchResultSelected(
                query: query,
                mediaId: mediaId,
                mediaType: mediaType,
                position: position,
                resultCount: resultCount
            ),
            context: context
        )
    }

    func logLanguageChanged(from: String, to: String) {
        track(.languageChanged(from: from, to: to))
        setPersonProperties(["preferred_language": to])
    }

    // MARK: - Diagnostics

    func diagnostics() -> Diagnostics {
        Diagnostics(
            isConfigured: backend != nil,
            isEnabled: isEnabled,
            distinctId: backend?.distinctId(),
            isReplayActive: backend?.isSessionReplayActive() ?? false
        )
    }

    func flushNow() {
        backend?.flush()
    }

    func logDiagnostics() {
        Logger.info("[Analytics] Status check:")
        Logger.info("[Analytics]   - Enabled: \(isEnabled)")
        Logger.info("[Analytics]   - User ID: \(userId ?? "anonymous")")
        Logger.info("[Analytics]   - Install ID: \(installId)")
        Logger.info("[Analytics]   - Backend configured: \(backend != nil)")
        Logger.info("[Analytics]   - PostHog Host: \(Config.posthogHost.isEmpty ? "MISSING" : Config.posthogHost)")
    }

    func recentEvents(limit: Int) -> [EventSnapshot] {
        events.suffix(limit).map { EventSnapshot(name: $0.name, parameters: $0.parameters, timestamp: $0.timestamp) }
    }

    // MARK: - Internal helpers

    private func logEventLocal(_ name: String, parameters: [String: Any]?) {
        events.append((name, parameters, Date()))
        if events.count > 100 {
            events.removeFirst()
        }
        Logger.debug("[Analytics] Event: \(name) \(parameters?.isEmpty == false ? "with params" : "")")
    }

    private func mergedParameters(
        _ parameters: [String: Any],
        context: AnalyticsContext?
    ) -> [String: Any]? {
        var merged = parameters
        if let context {
            for (key, value) in context.properties() {
                merged[key] = value
            }
        }
        return merged.isEmpty ? nil : merged
    }

    #if DEBUG
    /// Test hook: inject a spy backend and reset consent state.
    func _setBackendForTesting(_ backend: AnalyticsBackend?, enabled: Bool = true) {
        self.backend = backend
        self.replay = SessionReplayController(backend: backend)
        self.isEnabled = enabled
        self.userId = nil
        self.events.removeAll()
    }
    #endif
}
