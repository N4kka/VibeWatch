import Foundation

/// Decides *when* session replay records. The SDK is configured with replay armed but stopped:
/// recording a user who opens the app and wanders for five minutes is noise, so a session is
/// recorded only from the moment it becomes interesting — a core action (rating, list add,
/// search→detail, social interaction, share, import) or a handled error.
///
/// Once started, recording runs to the end of the session; PostHog links the replay to every
/// event captured while it is active.
@MainActor
final class SessionReplayController {

    enum Trigger {
        /// A core-feature action, tagged with the event name that fired it.
        case coreAction(String)
        /// A handled error — recording starts at the error, not retroactively.
        case errorHandled
        /// A crash caught in-process (uncaught NSException path).
        case crash

        var rawValue: String {
            switch self {
            case .coreAction(let event): return event
            case .errorHandled: return "error_handled"
            case .crash: return "crash"
            }
        }
    }

    private weak var backend: AnalyticsBackend?

    init(backend: AnalyticsBackend?) {
        self.backend = backend
    }

    /// Starts recording if it isn't already running. `resumeCurrent: true` keeps the current
    /// session id, so the events captured before the trigger stay tied to the same session.
    func trigger(_ trigger: Trigger) {
        guard let backend, !backend.isSessionReplayActive() else { return }
        backend.startSessionRecording(resumeCurrent: true)
        let marker = AnalyticsEvent.replayStarted(trigger: trigger.rawValue)
        backend.capture(marker.name, properties: marker.properties, userProperties: nil)
        Logger.info("[Replay] Recording started (trigger: \(trigger.rawValue))")
    }

    /// Opt-out kills an in-flight recording immediately.
    func stopIfActive() {
        guard let backend, backend.isSessionReplayActive() else { return }
        backend.stopSessionRecording()
        Logger.info("[Replay] Recording stopped (opt-out)")
    }
}
