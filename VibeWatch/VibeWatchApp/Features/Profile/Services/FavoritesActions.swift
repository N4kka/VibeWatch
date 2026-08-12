import Foundation

/// Le scritture dei favorites (§3.6, blocco 9): riempire uno slot e svuotarlo.
///
/// Stessa forma di `RatingActions`: l'identità (`user_id`) si riempie qui e solo qui, la forma
/// fuori regola (slot fuori da 1-4, media_type che non è film o serie) è un errore vero prima di
/// accodare — non un rifiuto muto in `sync_rejected_mutations` — e dopo ogni scrittura si
/// rilegge dal server.
@MainActor
final class FavoritesActions {
    static let shared = FavoritesActions()

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
        case invalidSlot
        case invalidMediaType

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "You must be signed in to set favorites"
            case .invalidSlot: return "Favorites have 4 slots per kind"
            case .invalidMediaType: return "A favorite is a movie or a TV show"
            }
        }
    }

    /// Mettere un titolo in uno slot già pieno lo sostituisce: la PK è lo slot (l'ordine conta,
    /// §3.6), quindi l'upsert converge da solo, qui come sul server.
    func setFavorite(mediaType: String, slot: Int, tmdbId: Int) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }
        guard ["movie", "tv"].contains(mediaType) else { throw ActionError.invalidMediaType }
        guard (1...4).contains(slot) else { throw ActionError.invalidSlot }

        let record: [String: Any] = [
            "user_id": userId,
            "media_type": mediaType,
            "slot": slot,
            "tmdb_id": tmdbId,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]

        try await sqlite.upsert(table: "user_favorites", rows: [record])
        // L'upsert non tocca le colonne che il record non porta: riempire uno slot svuotato
        // lascerebbe la lapide locale. Si toglie esplicitamente.
        try await sqlite.executeWrite(
            "UPDATE user_favorites SET deleted_at = NULL WHERE user_id = ? AND media_type = ? AND slot = ?",
            parameters: [userId, mediaType, slot]
        )

        try await syncEngine.queueOperation(
            table: "user_favorites",
            operationType: "UPSERT",
            recordId: "\(mediaType):\(slot)",
            payload: record,
            dependsOn: nil
        )
        await syncEngine.pullProfileContent()
    }

    /// Svuotare uno slot è una lapide, non una DELETE fisica: il ramo DELETE di
    /// `apply_mutations` riceve (media_type, slot) nel record e scrive `deleted_at` sul server,
    /// così il pull porta lo slot vuoto anche agli altri dispositivi.
    func clearFavorite(mediaType: String, slot: Int) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }
        guard ["movie", "tv"].contains(mediaType) else { throw ActionError.invalidMediaType }
        guard (1...4).contains(slot) else { throw ActionError.invalidSlot }

        try await sqlite.executeWrite(
            "UPDATE user_favorites SET deleted_at = ? WHERE user_id = ? AND media_type = ? AND slot = ?",
            parameters: [ISO8601DateFormatter().string(from: Date()), userId, mediaType, slot]
        )

        try await syncEngine.queueOperation(
            table: "user_favorites",
            operationType: "DELETE",
            recordId: "\(mediaType):\(slot)",
            payload: ["media_type": mediaType, "slot": slot],
            dependsOn: nil
        )
        await syncEngine.pullProfileContent()
    }
}
