import Foundation
import PostHog

/// The subset of the analytics SDK the app actually uses. Abstracted so nothing outside this file
/// imports PostHog, and so tests can assert what gets captured without an SDK in the loop.
/// Deliberately not actor-isolated: `PostHogSDK` is thread-safe, and the crash reporter needs to
/// call it from any thread.
protocol AnalyticsBackend: AnyObject {
    func capture(_ event: String, properties: [String: Any]?, userProperties: [String: Any]?)
    func screen(_ name: String, properties: [String: Any]?)
    func identify(_ distinctId: String, userProperties: [String: Any]?, userPropertiesSetOnce: [String: Any]?)
    func reset()
    func optIn()
    func optOut()
    func register(_ superProperties: [String: Any])
    func captureException(_ error: Error, properties: [String: Any]?)
    func addExceptionStep(_ message: String, properties: [String: Any]?)
    func startSessionRecording(resumeCurrent: Bool)
    func stopSessionRecording()
    func isSessionReplayActive() -> Bool
    func distinctId() -> String
    func flush()
}

/// The real backend: a stateless pass-through to the thread-safe `PostHogSDK` singleton.
final class PostHogAnalyticsBackend: AnalyticsBackend {

    /// Schema marker for every event sent by this implementation. Old builds (2.x with the
    /// hand-rolled client) keep sending the legacy taxonomy for months — dashboards filter on
    /// `schema_version = 3` to see only the new one.
    static let schemaVersion = 3

    /// Sets up `PostHogSDK.shared` from bundle config. Returns nil when the keys are missing
    /// (clean checkout without Secrets.xcconfig): the facade then runs against a no-op-ish state
    /// where nothing is captured, mirroring the old client's silent-drop behaviour.
    static func bootstrap(isEnabled: Bool, installId: String) -> PostHogAnalyticsBackend? {
        let apiKey = Config.posthogApiKey
        let host = Config.posthogHost
        guard !apiKey.isEmpty, !host.isEmpty else {
            Logger.error("[Analytics] PostHog credentials missing — analytics disabled for this run")
            return nil
        }

        let config = PostHogConfig(apiKey: apiKey, host: host)
        // Application Installed/Updated/Opened/Backgrounded — feeds PostHog's default dashboards.
        config.captureApplicationLifecycleEvents = true
        // UIKit screen swizzling is useless with SwiftUI: screens are tracked manually.
        config.captureScreenViews = false
        // Element interaction autocapture (heatmap-like usage data on the real UI).
        config.captureElementInteractions = true
        // Person profiles only for identified users: anonymous events stay cheap.
        config.personProfiles = .identifiedOnly
        // The user's choice from Settings has to hold before the first event fires.
        config.optOut = !isEnabled
        // Crash + handled-error autocapture ($exception with stack traces).
        config.errorTrackingConfig.autoCapture = true
        // Session replay is armed but never records on its own: recording starts only from
        // SessionReplayController when a core action or an error makes the session interesting.
        config.sessionReplay = true
        config.sessionReplayConfig.screenshotMode = true // required for SwiftUI
        config.sessionReplayConfig.maskAllTextInputs = true
        // Posters and public avatars are the content; nothing sensitive is rendered in images.
        config.sessionReplayConfig.maskAllImages = false

        PostHogSDK.shared.setup(config)
        // Replay stays off until explicitly triggered.
        PostHogSDK.shared.stopSessionRecording()

        let backend = PostHogAnalyticsBackend()
        backend.register([
            "install_id": installId,
            "schema_version": schemaVersion,
        ])
        return backend
    }

    func capture(_ event: String, properties: [String: Any]?, userProperties: [String: Any]?) {
        PostHogSDK.shared.capture(event, properties: properties, userProperties: userProperties)
    }

    func screen(_ name: String, properties: [String: Any]?) {
        PostHogSDK.shared.screen(name, properties: properties)
    }

    func identify(_ distinctId: String, userProperties: [String: Any]?, userPropertiesSetOnce: [String: Any]?) {
        PostHogSDK.shared.identify(
            distinctId,
            userProperties: userProperties,
            userPropertiesSetOnce: userPropertiesSetOnce
        )
    }

    func reset() {
        PostHogSDK.shared.reset()
    }

    func optIn() {
        PostHogSDK.shared.optIn()
    }

    func optOut() {
        PostHogSDK.shared.optOut()
    }

    func register(_ superProperties: [String: Any]) {
        PostHogSDK.shared.register(superProperties)
    }

    func captureException(_ error: Error, properties: [String: Any]?) {
        PostHogSDK.shared.captureException(error, properties: properties)
    }

    func addExceptionStep(_ message: String, properties: [String: Any]?) {
        PostHogSDK.shared.addExceptionStep(message, properties: properties)
    }

    func startSessionRecording(resumeCurrent: Bool) {
        PostHogSDK.shared.startSessionRecording(resumeCurrent: resumeCurrent)
    }

    func stopSessionRecording() {
        PostHogSDK.shared.stopSessionRecording()
    }

    func isSessionReplayActive() -> Bool {
        PostHogSDK.shared.isSessionReplayActive()
    }

    func distinctId() -> String {
        PostHogSDK.shared.getDistinctId()
    }

    func flush() {
        PostHogSDK.shared.flush()
    }
}
