import Foundation

// MARK: - Error Types

public enum SyncError: LocalizedError {
    case remoteUnavailable
    case unknownOperation(String)
    case invalidPayload
    
    public var errorDescription: String? {
        switch self {
        case .remoteUnavailable:
            return "Remote database is unavailable"
        case .unknownOperation(let type):
            return "Unknown operation type: \(type)"
        case .invalidPayload:
            return "Invalid operation payload"
        }
    }
}
