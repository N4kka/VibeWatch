import Foundation

@MainActor
final class ConversationMemoryManager: ObservableObject {
    static let shared = ConversationMemoryManager()

    private let sqliteService: SQLiteService
    private let maxMessages: Int

    @Published private(set) var sessionId: String
    @Published private(set) var messages: [AIChatMessage] = []

    private init(
        sqliteService: SQLiteService = .shared,
        maxMessages: Int = 10
    ) {
        self.sqliteService = sqliteService
        self.maxMessages = maxMessages

        if let existing = UserDefaults.standard.string(forKey: "ai_chat_session_id") {
            self.sessionId = existing
        } else {
            let created = UUID().uuidString
            UserDefaults.standard.set(created, forKey: "ai_chat_session_id")
            self.sessionId = created
        }
    }

    func loadSessionIfNeeded() async {
        guard let userId = AuthService.shared.currentUser?.id else {
            messages = []
            return
        }

        do {
            let rows = try await sqliteService.queryRaw(
                """
                SELECT message_type, content, created_at
                FROM ai_conversation_history
                WHERE user_id = ? AND session_id = ?
                ORDER BY created_at ASC
                LIMIT ?
                """,
                parameters: [userId, sessionId, maxMessages]
            )

            messages = rows.compactMap { row in
                guard let messageType = row["message_type"] as? String,
                      let content = row["content"] as? String else {
                    return nil
                }

                let role: AIChatRole
                switch messageType.lowercased() {
                case "user": role = .user
                case "assistant": role = .assistant
                case "system": role = .system
                default: role = .assistant
                }

                return AIChatMessage(role: role, content: content)
            }
        } catch {
            Logger.error("[ConversationMemoryManager] Failed to load conversation history", error: error)
            messages = []
        }
    }

    func recentMessages(limit: Int? = nil) -> [AIChatMessage] {
        let maxCount = min(limit ?? maxMessages, maxMessages)
        return Array(messages.suffix(maxCount))
    }

    func append(
        role: AIChatRole,
        content: String,
        queryType: String? = nil,
        mentionedMediaIds: [Int] = [],
        mentionedGenres: [String] = [],
        tokensUsed: Int? = nil
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(AIChatMessage(role: role, content: trimmed))
        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }

        guard let userId = AuthService.shared.currentUser?.id else {
            return
        }

        let deviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") ?? "unknown"
        let now = ISO8601DateFormatter().string(from: Date())

        let record: [String: Any] = [
            "id": UUID().uuidString,
            "user_id": userId,
            "device_id": deviceId,
            "session_id": sessionId,
            "message_type": role.rawValue,
            "content": trimmed,
            "query_type": queryType ?? NSNull(),
            "mentioned_media_ids": mentionedMediaIds.isEmpty ? NSNull() : mentionedMediaIds,
            "mentioned_genres": mentionedGenres.isEmpty ? NSNull() : mentionedGenres,
            "tokens_used": tokensUsed ?? NSNull(),
            "created_at": now
        ]

        do {
            _ = try await sqliteService.insert(
                "ai_conversation_history",
                values: record
            )

            let recordId = record["id"] as? String ?? UUID().uuidString
            do {
                try await SyncEngine.shared.queueOperation(
                    table: "ai_conversation_history",
                    operationType: "INSERT",
                    recordId: recordId,
                    payload: record,
                    dependsOn: nil
                )
            } catch {
                Logger.error("[ConversationMemoryManager] Failed to queue sync: \(error)")
            }
        } catch {
            Logger.error("[ConversationMemoryManager] Failed to persist conversation message", error: error)
        }
    }

    func resetSession() async {
        let newSession = UUID().uuidString
        UserDefaults.standard.set(newSession, forKey: "ai_chat_session_id")
        sessionId = newSession
        messages = []
    }
}
