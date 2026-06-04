import Foundation

/// Polls a readiness predicate until it becomes true or a deadline elapses.
///
/// Used by the splash screen to dismiss as soon as content is ready instead of
/// busy-waiting a fixed timeout. Returns `true` if the predicate became true
/// before `maxWait` elapsed, `false` on timeout.
enum ReadinessWaiter {
    static func waitUntilReady(
        maxWait: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        isReady: () -> Bool
    ) async -> Bool {
        if isReady() { return true }

        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if isReady() { return true }
        }
        return isReady()
    }
}
