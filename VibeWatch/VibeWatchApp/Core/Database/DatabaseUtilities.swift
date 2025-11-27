import Foundation

enum DatabaseUtilities {
    /// Executes a given asynchronous operation within a database transaction.
    ///
    /// - Parameter operation: The asynchronous operation to perform.
    /// - Returns: The result of the operation.
    /// - Throws: Any error thrown by the operation.
    static func executeInTransaction<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        // Shared transaction logic (conceptual, actual implementation would depend on database library)
        print("BEGIN TRANSACTION (conceptual)")
        do {
            let result = try await operation()
            print("COMMIT TRANSACTION (conceptual)")
            return result
        } catch {
            print("ROLLBACK TRANSACTION (conceptual)")
            throw error
        }
    }
    
    /// Retries an asynchronous operation a specified number of times if it fails.
    ///
    /// - Parameters:
    ///   - maxAttempts: The maximum number of times to retry the operation (default: 3).
    ///   - operation: The asynchronous operation to perform.
    /// - Returns: The result of the successful operation.
    /// - Throws: The last error encountered if all retries fail.
    static func retryOnFailure<T>(
        maxAttempts: Int = 3,
        delay: TimeInterval = 1.0, // Delay between retries
        _ operation: () async throws -> T
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
