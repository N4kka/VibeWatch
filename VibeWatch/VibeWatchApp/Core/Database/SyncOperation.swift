import Foundation

// MARK: - Models

public struct SyncOperation {
    public let id: Int
    public let operationId: String
    public let userId: String
    public let tableName: String
    public let operationType: String
    public let recordId: String
    public let payload: [String: Any]
    public let attempts: Int
    public let status: String
    public let nextRetryAt: Date?
    
    public init?(row: [String: Any]) {
        guard
            let id = row["id"] as? Int,
            let operationId = row["operation_id"] as? String,
            let userId = row["user_id"] as? String,
            let tableName = row["table_name"] as? String,
            let operationType = row["operation_type"] as? String,
            let recordId = row["record_id"] as? String,
            let payloadString = row["payload"] as? String,
            let payloadData = payloadString.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
            let status = row["status"] as? String
        else {
            Logger.warning("Failed to parse sync operation row")
            return nil
        }
        
        self.id = id
        self.operationId = operationId
        self.userId = userId
        self.tableName = tableName
        self.operationType = operationType
        self.recordId = recordId
        self.payload = payload
        self.attempts = row["attempts"] as? Int ?? 0
        self.status = status
        
        // Parse next_retry_at if present
        if let retryString = row["next_retry_at"] as? String {
            let formatter = ISO8601DateFormatter()
            self.nextRetryAt = formatter.date(from: retryString)
        } else {
            self.nextRetryAt = nil
        }
    }
}
