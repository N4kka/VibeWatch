import Foundation

enum DatabaseUtilities {
    // `executeInTransaction` used to live here. It never opened a transaction — it logged
    // "BEGIN TRANSACTION (conceptual)" and called the closure — so its one caller that actually
    // relied on it for atomicity (DatabaseMigrationService.migrateDiscoveryCache) had none.
    // Use `SQLiteService.transaction` instead, which issues real BEGIN/COMMIT/ROLLBACK.

    /// Retries an asynchronous operation a specified number of times if it fails.
    ///
    /// - Parameters:
    ///   - maxAttempts: The maximum number of times to retry the operation (default: 3).
    ///   - operation: The asynchronous operation to perform.
    /// - Returns: The result of the successful operation.
    /// - Throws: The last error encountered if all retries fail.
    @MainActor
    static func retryOnFailure<T>(
        maxAttempts: Int = 3,
        delay: TimeInterval = 1.0, // Delay between retries
        _ operation: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                Logger.warning("Attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? AppError.unknown(nil) // Should not happen
    }
}
