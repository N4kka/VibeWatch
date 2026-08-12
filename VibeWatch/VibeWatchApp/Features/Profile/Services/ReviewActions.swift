import Foundation

/// Le scritture della review breve (social feed M1): scrivere e togliere la one-liner.
///
/// **Perché una classe, come `RatingActions` e le sue sorelle.** `apply_mutations` confronta
/// `rec->>'user_id'` con `auth.uid()` e, se non combacia o manca, registra `user_id_mismatch`
/// in `sync_rejected_mutations` **e prosegue**: il posto in cui `user_id` viene riempito deve
/// essere uno solo.
///
/// **La forma si rifiuta prima di accodare.** Un contenuto vuoto o oltre i 280 caratteri
/// (trimmati, come il CHECK del server) morirebbe come rifiuto muto; qui diventa un errore
/// vero, subito.
///
/// **L'id lo genera il client, e si riusa.** A differenza di `user_ratings` la tabella ha un
/// id sintetico (report e `activities.review_id` lo referenziano): riscrivere la review di un
/// titolo riusa l'id della riga viva locale, così due salvataggi sono la stessa riga e non due.
/// Se due dispositivi offline ne generano comunque due, converge `apply_mutations` mettendo la
/// lapide all'altra riga viva della stessa chiave naturale.
///
/// **Dopo la scrittura si rilegge** (`pullProfileContent`): la scrittura passa dall'outbox e lo
/// specchio locale è ottimistico, ma se il server la respinge solo un pull riallinea lo schermo.
@MainActor
final class ReviewActions {
    static let shared = ReviewActions()

    /// Il limite del CHECK remoto, sul contenuto trimmato: 280 spazi non sono una review.
    static let maxContentLength = 280

    private let syncEngine: any SyncEngineProtocol
    private let sqlite: SQLiteService
    private let currentUserId: @MainActor () -> String?

    init(
        syncEngine: any SyncEngineProtocol = SyncEngine.shared,
        sqlite: SQLiteService = .shared,
        currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }
    ) {
        self.syncEngine = syncEngine
        self.sqlite = sqlite
        self.currentUserId = currentUserId
    }

    enum ActionError: LocalizedError {
        case notAuthenticated
        case invalidContent
        case invalidMediaType

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "You must be signed in to review"
            case .invalidContent: return "A review is 1 to 280 characters once trimmed"
            case .invalidMediaType: return "A review belongs to a movie or a show"
            }
        }
    }

    /// La review viva di un titolo, come la legge la UI.
    struct LocalReview: Equatable {
        let id: String
        let content: String
        let containsSpoilers: Bool
    }

    /// Scrive (o riscrive) la review di un titolo. Il contenuto viene trimmato e validato qui,
    /// specchio del CHECK `char_length(btrim(content)) between 1 and 280`: respinto dove
    /// l'errore si vede, non in `sync_rejected_mutations`.
    func setReview(mediaType: String, tmdbId: Int,
                   content: String, containsSpoilers: Bool = false) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }
        guard ["movie", "tv"].contains(mediaType) else { throw ActionError.invalidMediaType }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maxContentLength).contains(trimmed.count) else {
            throw ActionError.invalidContent
        }

        // L'id della riga viva si riusa: il re-write è la stessa review, non una seconda.
        let id = await liveReviewId(userId: userId, mediaType: mediaType, tmdbId: tmdbId)
            ?? UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())

        let record: [String: Any] = [
            "id": id,
            "user_id": userId,
            "media_type": mediaType,
            "tmdb_id": tmdbId,
            "content": trimmed,
            "contains_spoilers": containsSpoilers,
            "updated_at": now,
        ]

        try await sqlite.upsert(table: "user_reviews", rows: [record])
        // L'upsert non tocca le colonne che il record non porta: su un re-write dopo una
        // cancellazione la lapide locale resterebbe. Si toglie esplicitamente.
        try await sqlite.executeWrite(
            "UPDATE user_reviews SET deleted_at = NULL WHERE id = ?",
            parameters: [id]
        )

        try await syncEngine.queueOperation(
            table: "user_reviews",
            operationType: "UPSERT",
            recordId: id,
            payload: record,
            dependsOn: nil
        )
        await syncEngine.pullProfileContent()
    }

    /// Togliere una review è una lapide, non una DELETE fisica (il grant nemmeno esiste): il
    /// ramo DELETE di `apply_mutations` cerca la riga per id, quindi il record lo deve portare.
    func removeReview(mediaType: String, tmdbId: Int) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }

        // Senza una riga viva non c'è niente da togliere: nessuna mutazione inventata.
        guard let id = await liveReviewId(userId: userId, mediaType: mediaType, tmdbId: tmdbId) else {
            return
        }

        try await sqlite.executeWrite(
            "UPDATE user_reviews SET deleted_at = ? WHERE id = ?",
            parameters: [ISO8601DateFormatter().string(from: Date()), id]
        )

        try await syncEngine.queueOperation(
            table: "user_reviews",
            operationType: "DELETE",
            recordId: id,
            payload: ["id": id],
            dependsOn: nil
        )
        await syncEngine.pullProfileContent()
    }

    /// La review viva del titolo, dallo specchio locale: è ciò che la UI mostra e pre-compila.
    func review(for mediaType: String, tmdbId: Int) async -> LocalReview? {
        guard let userId = currentUserId() else { return nil }
        let rows = (try? await sqlite.queryRaw(
            """
            SELECT id, content, contains_spoilers FROM user_reviews
            WHERE user_id = ? AND media_type = ? AND tmdb_id = ? AND deleted_at IS NULL
            LIMIT 1
            """,
            parameters: [userId, mediaType, tmdbId]
        )) ?? []
        guard let row = rows.first,
              let id = row["id"] as? String,
              let content = row["content"] as? String else { return nil }
        return LocalReview(id: id, content: content,
                           containsSpoilers: (row["contains_spoilers"] as? Int ?? 0) != 0)
    }

    /// L'id della riga viva per (utente, titolo), se esiste nello specchio locale.
    private func liveReviewId(userId: String, mediaType: String, tmdbId: Int) async -> String? {
        let rows = (try? await sqlite.queryRaw(
            """
            SELECT id FROM user_reviews
            WHERE user_id = ? AND media_type = ? AND tmdb_id = ? AND deleted_at IS NULL
            LIMIT 1
            """,
            parameters: [userId, mediaType, tmdbId]
        )) ?? []
        return rows.first?["id"] as? String
    }
}
