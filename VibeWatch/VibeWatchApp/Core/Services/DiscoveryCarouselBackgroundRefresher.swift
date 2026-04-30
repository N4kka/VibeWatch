import Foundation
import BackgroundTasks

@MainActor
final class DiscoveryCarouselBackgroundRefresher {
    static let shared = DiscoveryCarouselBackgroundRefresher()

    static let taskIdentifier = "com.vibewatch.refresh-carousels"

    private init() {}

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(task: refreshTask)
        }
    }

    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = nextLocalMidnightAdding(minutes: 10)

        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.debug("[DiscoveryCarouselBackgroundRefresher] Scheduled app refresh")
        } catch {
            Logger.error("[DiscoveryCarouselBackgroundRefresher] Failed to schedule app refresh", error: error)
        }
    }

    private func nextLocalMidnightAdding(minutes: Int) -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date().addingTimeInterval(86400)
        return calendar.date(byAdding: .minute, value: minutes, to: nextMidnight) ?? nextMidnight
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleNextRefresh()

        let operationTask = Task { @MainActor in
            defer { task.setTaskCompleted(success: true) }

            await refreshNow()
        }

        task.expirationHandler = {
            Logger.warning("[DiscoveryCarouselBackgroundRefresher] Background task expired")
            operationTask.cancel()
        }
    }

    func refreshNow() async {
        guard AuthService.shared.currentUser?.id != nil else {
            return
        }

        Logger.info("[DiscoveryCarouselBackgroundRefresher] 🌙 Background refresh started")

        let profile = await UserPreferenceManager.shared.aggregatePreferences()
        let filters = GlobalDiscoveryFilters.load()

        _ = try? await DiscoveryPersonalizationService.shared.generatePersonalizedCarousels(
            userProfile: profile,
            filters: filters,
            forceRefresh: true
        )

        Logger.info("[DiscoveryCarouselBackgroundRefresher] ✅ Background refresh completed")
    }
}
