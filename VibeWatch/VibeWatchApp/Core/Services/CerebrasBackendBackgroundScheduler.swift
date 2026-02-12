import Foundation
import BackgroundTasks

@MainActor
final class CerebrasBackendBackgroundScheduler {
    static let shared = CerebrasBackendBackgroundScheduler()

    static let taskIdentifier = "com.vibewatch.cerebras-backend-processing"

    private init() {}

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleProcessing(task: processingTask)
        }
    }

    func scheduleNextRun() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        request.earliestBeginDate = nextLocalMidnightAdding(minutes: 20)

        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.debug("[CerebrasBackendBackgroundScheduler] Scheduled background processing")
        } catch {
            Logger.error("[CerebrasBackendBackgroundScheduler] Failed to schedule background processing", error: error)
        }
    }

    private func nextLocalMidnightAdding(minutes: Int) -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date().addingTimeInterval(86400)
        return calendar.date(byAdding: .minute, value: minutes, to: nextMidnight) ?? nextMidnight
    }

    private func handleProcessing(task: BGProcessingTask) {
        scheduleNextRun()

        let operationTask = Task { @MainActor in
            await CerebrasBackendJobManager.shared.enqueueDailyJobsIfNeeded()
            await CerebrasBackendJobManager.shared.processPendingJobs(maxJobs: 4, timeBudgetSeconds: 25)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            operationTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
