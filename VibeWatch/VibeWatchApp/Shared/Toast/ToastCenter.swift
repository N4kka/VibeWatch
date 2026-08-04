import Foundation
import SwiftUI

/// Central, app-wide toast queue with an explicit progress → completed/failed lifecycle.
///
/// The toast is rendered on a dedicated passthrough `UIWindow` (see `ToastWindowMounter`) so it
/// stays visible above sheets and full screen covers.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        enum Phase: Equatable {
            case progress
            case success
            case failure
        }

        let id: String
        var message: String
        var phase: Phase
    }

    /// Auto-dismiss delays per terminal phase, plus the floor on the progress phase.
    enum Delay {
        static let success: TimeInterval = 1.8
        static let failure: TimeInterval = 2.5
        /// Most mutations settle in a few milliseconds: without a floor the progress bar would
        /// flash by unseen and every toast would look like it skipped straight to "done".
        /// Only the graphic transition waits — the operation itself is never slowed down.
        static let minimumProgress: TimeInterval = 0.45
    }

    /// Maximum number of toasts waiting behind an in-flight progress toast.
    private static let maxQueued = 3

    @Published private(set) var current: Toast?

    /// Injectable for tests so auto-dismiss does not depend on wall clock.
    var sleeper: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Mounts the toast window lazily; overridable in tests to avoid touching UIKit.
    var mounter: () -> Void = { ToastWindowMounter.mountIfNeeded() }

    private var queue: [Toast] = []
    private var dismissTask: Task<Void, Never>?
    /// Non-nil while the current progress toast is still serving its minimum on-screen time.
    private var progressHoldTask: Task<Void, Never>?
    /// A terminal transition that arrived before the progress floor elapsed.
    private var pendingTerminal: (phase: Toast.Phase, message: String?)?

    init() {}

    // MARK: - Lifecycle

    /// Starts a toast in the `progress` phase. Returns the id used to complete or fail it.
    @discardableResult
    func begin(id: String = UUID().uuidString, message: String) -> String {
        mounter()
        enqueue(Toast(id: id, message: message, phase: .progress))
        return id
    }

    /// Moves a toast to `success`; it auto-dismisses shortly after.
    func complete(_ id: String, message: String? = nil) {
        transition(id, to: .success, message: message)
    }

    /// Moves a toast to `failure`; it auto-dismisses shortly after.
    func fail(_ id: String, message: String? = nil) {
        transition(id, to: .failure, message: message)
    }

    /// Shows a success toast without a preceding progress phase.
    func show(success message: String) {
        mounter()
        enqueue(Toast(id: UUID().uuidString, message: message, phase: .success))
    }

    /// Shows a failure toast without a preceding progress phase.
    func show(error message: String) {
        mounter()
        enqueue(Toast(id: UUID().uuidString, message: message, phase: .failure))
    }

    /// Wraps an async operation: progress while it runs, success or failure when it settles.
    @discardableResult
    func run<T>(
        _ progress: String,
        success: String,
        failure: String? = nil,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let id = begin(message: progress)
        do {
            let value = try await operation()
            complete(id, message: success)
            return value
        } catch {
            fail(id, message: failure ?? error.localizedDescription)
            throw error
        }
    }

    /// Clears everything (used when the presenting context goes away, and by tests).
    func reset() {
        dismissTask?.cancel()
        dismissTask = nil
        progressHoldTask?.cancel()
        progressHoldTask = nil
        pendingTerminal = nil
        queue.removeAll()
        current = nil
    }

    // MARK: - Queue

    private func enqueue(_ toast: Toast) {
        guard let active = current else {
            present(toast)
            return
        }
        // A progress toast is never interrupted: newcomers wait their turn (FIFO, bounded).
        if active.phase == .progress {
            queue.append(toast)
            if queue.count > Self.maxQueued { queue.removeFirst() }
        } else {
            present(toast)
        }
    }

    private func present(_ toast: Toast) {
        dismissTask?.cancel()
        dismissTask = nil
        progressHoldTask?.cancel()
        progressHoldTask = nil
        pendingTerminal = nil
        current = toast
        guard toast.phase != .progress else {
            holdProgress(for: toast)
            return
        }
        scheduleDismiss(for: toast)
    }

    /// Keeps the progress phase on screen for `Delay.minimumProgress` before letting a terminal
    /// phase replace it.
    private func holdProgress(for toast: Toast) {
        progressHoldTask = Task { [weak self] in
            guard let self else { return }
            await self.sleeper(Delay.minimumProgress)
            guard !Task.isCancelled else { return }
            self.releaseProgressHold(for: toast)
        }
    }

    private func releaseProgressHold(for toast: Toast) {
        guard current?.id == toast.id, current?.phase == .progress else { return }
        progressHoldTask = nil
        guard let pending = pendingTerminal else { return }
        pendingTerminal = nil
        var updated = toast
        updated.phase = pending.phase
        if let message = pending.message { updated.message = message }
        present(updated)
    }

    private func scheduleDismiss(for toast: Toast) {
        let delay = toast.phase == .failure ? Delay.failure : Delay.success
        dismissTask = Task { [weak self] in
            guard let self else { return }
            await self.sleeper(delay)
            guard !Task.isCancelled else { return }
            self.advance(after: toast)
        }
    }

    private func advance(after toast: Toast) {
        guard current?.id == toast.id, current?.phase == toast.phase else { return }
        dismissTask = nil
        if queue.isEmpty {
            current = nil
        } else {
            present(queue.removeFirst())
        }
    }

    private func transition(_ id: String, to phase: Toast.Phase, message: String?) {
        if current?.id == id, var updated = current {
            // Il progresso è appena comparso: la fase terminale aspetta il suo turno, così la
            // barra si vede sempre almeno un istante.
            if updated.phase == .progress, progressHoldTask != nil {
                pendingTerminal = (phase, message)
                return
            }
            updated.phase = phase
            if let message { updated.message = message }
            present(updated)
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].phase = phase
        if let message { queue[index].message = message }
    }
}
