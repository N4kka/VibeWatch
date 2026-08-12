import Foundation

/// Riassunto di una sessione chat per la lista "Le tue chat". Il titolo è un'euristica (primo
/// messaggio utente troncato), mai storata: funziona anche retroattivamente sulle chat vecchie.
struct AIChatSessionSummary: Identifiable, Equatable {
    let sessionId: String
    let title: String
    let lastMessageAt: Date
    let messageCount: Int
    /// Id TMDB distinti proposti dall'AI in questa sessione (da mentioned_media_ids).
    let proposedMediaIds: [Int]

    var id: String { sessionId }
}

@MainActor
final class ConversationMemoryManager: ObservableObject {
    static let shared = ConversationMemoryManager()

    private let sqliteService: SQLiteService
    private let maxMessages: Int
    /// Quanti messaggi caricare per la VISUALIZZAZIONE di una sessione (il contesto del modello
    /// resta cappato a maxMessages da recentMessages).
    private let displayLoadLimit = 100

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
                parameters: [userId, sessionId, displayLoadLimit]
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

        let deviceId = DeviceIdentity.installation
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

    /// Passa a una sessione esistente e ne ricarica i messaggi.
    func switchSession(to id: String) async {
        guard id != sessionId else { return }
        UserDefaults.standard.set(id, forKey: "ai_chat_session_id")
        sessionId = id
        messages = []
        await loadSessionIfNeeded()
    }

    /// Tutte le sessioni dell'utente, più recente prima, con titolo euristico e meta.
    func listSessions() async -> [AIChatSessionSummary] {
        guard let userId = AuthService.shared.currentUser?.id else { return [] }

        do {
            let rows = try await sqliteService.queryRaw(
                """
                SELECT h.session_id AS session_id,
                       MAX(h.created_at) AS last_at,
                       COUNT(*) AS msg_count,
                       (SELECT h2.content FROM ai_conversation_history h2
                         WHERE h2.session_id = h.session_id AND h2.message_type = 'user'
                         ORDER BY h2.created_at ASC LIMIT 1) AS first_user_msg,
                       GROUP_CONCAT(h.mentioned_media_ids) AS media_ids
                FROM ai_conversation_history h
                WHERE h.user_id = ?
                GROUP BY h.session_id
                ORDER BY last_at DESC
                """,
                parameters: [userId]
            )

            let isoFormatter = ISO8601DateFormatter()
            return rows.compactMap { row in
                guard let sessionId = row["session_id"] as? String else { return nil }
                let firstUserMessage = row["first_user_msg"] as? String
                // Sessioni senza alcun messaggio utente (solo system) non hanno senso in lista.
                guard let firstUserMessage, !firstUserMessage.isEmpty else { return nil }

                let lastAt = (row["last_at"] as? String).flatMap { isoFormatter.date(from: $0) } ?? .distantPast
                let count = (row["msg_count"] as? Int64).map(Int.init) ?? (row["msg_count"] as? Int ?? 0)

                return AIChatSessionSummary(
                    sessionId: sessionId,
                    title: Self.sessionTitle(from: firstUserMessage),
                    lastMessageAt: lastAt,
                    messageCount: count,
                    proposedMediaIds: Self.parseMediaIds(row["media_ids"] as? String)
                )
            }
        } catch {
            Logger.error("[ConversationMemoryManager] Failed to list sessions", error: error)
            return []
        }
    }

    /// Titolo euristico: primo messaggio utente, spazi collassati, troncato a confine di parola.
    static func sessionTitle(from firstUserMessage: String, maxLength: Int = 40) -> String {
        let collapsed = firstUserMessage
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        let cut = collapsed.prefix(maxLength)
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return trimmed + "…"
    }

    /// Estrae gli id TMDB distinti dal GROUP_CONCAT di mentioned_media_ids (valori serializzati
    /// come array JSON o liste separate da virgole: si va di regex sui numeri).
    private static func parseMediaIds(_ concatenated: String?) -> [Int] {
        guard let concatenated, !concatenated.isEmpty else { return [] }
        var seen = Set<Int>()
        var ordered: [Int] = []
        let scanner = Scanner(string: concatenated)
        scanner.charactersToBeSkipped = CharacterSet.decimalDigits.inverted
        while let value = scanner.scanInt() {
            if !seen.contains(value) {
                seen.insert(value)
                ordered.append(value)
            }
        }
        return ordered
    }
}
