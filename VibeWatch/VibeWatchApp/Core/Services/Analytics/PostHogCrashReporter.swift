import Foundation

/// `CrashReporter` implementation on top of PostHog error tracking.
///
/// Fatal crashes are handled by the SDK's autocapture (PLCrashReporter under the hood, enabled in
/// `PostHogAnalyticsBackend.bootstrap`); this class covers the rest of the protocol:
/// - `record` → a handled `$exception` event, correlated with events/replay of the same session
/// - `log` → an exception step (PostHog's breadcrumbs), attached to every following `$exception`
/// - `setCustomValue` → a super property, so it also lands on crash events
/// - collection enable/disable and user identity are owned by the analytics opt-out and
///   identify/reset flows, so here they are deliberate no-ops.
final class PostHogCrashReporter: CrashReporter {

    private weak var backend: AnalyticsBackend?

    init(backend: AnalyticsBackend?) {
        self.backend = backend
    }

    /// Covered by the SDK-wide `optIn()`/`optOut()` gate in `AnalyticsService.setEnabled`.
    func setCollectionEnabled(_ enabled: Bool) {}

    /// Covered by `AnalyticsService.setUserId` / `reset()` — one identity for events and errors.
    func setUserIdentifier(_ identifier: String?) {}

    func setCustomValue(_ value: Any, forKey key: String) {
        backend?.register([key: value])
    }

    func record(_ error: Error, userInfo: [String: Any]) {
        backend?.captureException(error, properties: userInfo)
    }

    func log(_ message: String) {
        backend?.addExceptionStep(message, properties: nil)
    }
}
