import Foundation

/// Le azioni sociali che scrivono: seguire e smettere di seguire.
///
/// **Perché una classe, come `TrackingActions`.** `apply_mutations` per `user_follows` confronta
/// `rec->>'follower_id'` con `auth.uid()` e, se non combacia o manca, scrive `user_id_mismatch`
/// in `sync_rejected_mutations` **e prosegue**: nessun errore arriva al client. Il posto in cui
/// `follower_id` viene riempito deve essere uno solo, e deve essere impossibile dimenticarlo.
///
/// **Il percorso è l'outbox** (§4, strategia `union`): la riga si scrive anche nello specchio
/// locale subito, così "seguo già" sopravvive offline; il server resta l'autorità su ciò che ne
/// consegue (contatori, `follows_me`), e chi mostra quei numeri li rilegge da `get_public_profile`.
@MainActor
final class SocialActions {
    static let shared = SocialActions()

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
        var errorDescription: String? { "You must be signed in to follow people" }
    }

    func follow(userId followeeId: String) async throws {
        try await write(followeeId: followeeId, deletedAt: nil)
    }

    func unfollow(userId followeeId: String) async throws {
        try await write(followeeId: followeeId, deletedAt: ISO8601DateFormatter().string(from: Date()))
    }

    /// Follow e unfollow sono la stessa scrittura con `deleted_at` diverso: il soft delete è
    /// l'unfollow e il re-follow riusa la riga, identico al server.
    private func write(followeeId: String, deletedAt: String?) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }

        var record: [String: Any] = [
            "follower_id": userId,
            "followee_id": followeeId,
        ]
        record["deleted_at"] = deletedAt

        // Lo specchio locale prima dell'outbox: lo stato "seguo" si vede subito e sopravvive
        // offline. La chiave è la coppia, quindi l'upsert converge da solo.
        try await sqlite.upsert(table: "user_follows", rows: [record])

        // `recordId` per user_follows è il followee: la PK è la coppia e il follower è sempre
        // il chiamante — è la convenzione del ramo DELETE di `apply_mutations`.
        try await syncEngine.queueOperation(
            table: "user_follows",
            operationType: "UPSERT",
            recordId: followeeId,
            payload: record,
            dependsOn: nil
        )
    }
}
