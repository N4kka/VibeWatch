import Foundation

/// Le scritture dei voti in stelle (§3.6, blocco 9): votare e togliere il voto.
///
/// **Perché una classe, come `TrackingActions` e `SocialActions`.** `apply_mutations` confronta
/// `rec->>'user_id'` con `auth.uid()` e, se non combacia o manca, registra `user_id_mismatch`
/// in `sync_rejected_mutations` **e prosegue**: nessun errore arriva al client. Il posto in cui
/// `user_id` viene riempito deve essere uno solo.
///
/// **La forma si rifiuta prima di accodare.** Un rating fuori da 1-10 o un voto a episodio senza
/// numeri morirebbe sul CHECK del server come rifiuto muto; qui diventa un errore vero, subito.
///
/// **Dopo la scrittura si rilegge** (`pullProfileContent`): la scrittura passa dall'outbox e lo
/// specchio locale è ottimistico, ma se il server la respinge solo un pull riallinea lo schermo.
@MainActor
final class RatingActions {
    static let shared = RatingActions()

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
        case invalidRating
        case invalidShape

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "You must be signed in to rate"
            case .invalidRating: return "A rating goes from half a star (1) to five stars (10)"
            case .invalidShape: return "An episode rating needs season and episode; a movie or show rating must not have them"
            }
        }
    }

    /// `rating` è un intero 1-10 = mezze stelle 0.5-5.0, identico al CHECK del server. Mai float.
    func rate(mediaType: String, tmdbId: Int,
              seasonNumber: Int? = nil, episodeNumber: Int? = nil,
              rating: Int) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }
        guard (1...10).contains(rating) else { throw ActionError.invalidRating }
        try validateShape(mediaType: mediaType, seasonNumber: seasonNumber, episodeNumber: episodeNumber)

        let now = ISO8601DateFormatter().string(from: Date())

        // Il record per il server parla la lingua del server: NULL (chiave assente) per
        // stagione/episodio quando non è un episodio.
        var record: [String: Any] = [
            "user_id": userId,
            "media_type": mediaType,
            "tmdb_id": tmdbId,
            "rating": rating,
            "updated_at": now,
        ]
        if let s = seasonNumber { record["season_number"] = s }
        if let e = episodeNumber { record["episode_number"] = e }

        // Lo specchio locale parla la lingua dello specchio: sentinello -1, come il
        // coalesce(-1) dell'indice unico remoto (vedi migration 11).
        var localRow = record
        localRow["season_number"] = seasonNumber ?? -1
        localRow["episode_number"] = episodeNumber ?? -1
        try await sqlite.upsert(table: "user_ratings", rows: [localRow])
        // L'upsert non tocca le colonne che il record non porta: su un re-voto dopo una
        // cancellazione la lapide locale resterebbe. Si toglie esplicitamente.
        try await sqlite.executeWrite(
            "UPDATE user_ratings SET deleted_at = NULL WHERE user_id = ? AND media_type = ? AND tmdb_id = ? AND season_number = ? AND episode_number = ?",
            parameters: [userId, mediaType, tmdbId, seasonNumber ?? -1, episodeNumber ?? -1]
        )

        try await syncEngine.queueOperation(
            table: "user_ratings",
            operationType: "UPSERT",
            recordId: recordKey(mediaType: mediaType, tmdbId: tmdbId,
                                seasonNumber: seasonNumber, episodeNumber: episodeNumber),
            payload: record,
            dependsOn: nil
        )
        AnalyticsService.shared.track(.mediaRated(
            mediaType: mediaType, mediaId: tmdbId, rating: Double(rating) / 2.0, previousRating: nil))
        await syncEngine.pullProfileContent()
    }

    /// Togliere un voto è una lapide, non una DELETE fisica (il grant nemmeno esiste): il ramo
    /// DELETE di `apply_mutations` riceve la chiave nel record e scrive `deleted_at` sul server.
    func removeRating(mediaType: String, tmdbId: Int,
                      seasonNumber: Int? = nil, episodeNumber: Int? = nil) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }
        try validateShape(mediaType: mediaType, seasonNumber: seasonNumber, episodeNumber: episodeNumber)

        try await sqlite.executeWrite(
            "UPDATE user_ratings SET deleted_at = ? WHERE user_id = ? AND media_type = ? AND tmdb_id = ? AND season_number = ? AND episode_number = ?",
            parameters: [ISO8601DateFormatter().string(from: Date()),
                         userId, mediaType, tmdbId, seasonNumber ?? -1, episodeNumber ?? -1]
        )

        var record: [String: Any] = [
            "media_type": mediaType,
            "tmdb_id": tmdbId,
        ]
        if let s = seasonNumber { record["season_number"] = s }
        if let e = episodeNumber { record["episode_number"] = e }

        try await syncEngine.queueOperation(
            table: "user_ratings",
            operationType: "DELETE",
            recordId: recordKey(mediaType: mediaType, tmdbId: tmdbId,
                                seasonNumber: seasonNumber, episodeNumber: episodeNumber),
            payload: record,
            dependsOn: nil
        )
        AnalyticsService.shared.track(.mediaRatingRemoved(mediaType: mediaType, mediaId: tmdbId))
        await syncEngine.pullProfileContent()
    }

    /// La stessa regola del CHECK `user_ratings_shape` sul server, rifiutata qui dove l'errore
    /// è visibile invece che in `sync_rejected_mutations`.
    private func validateShape(mediaType: String, seasonNumber: Int?, episodeNumber: Int?) throws {
        switch mediaType {
        case "episode":
            guard seasonNumber != nil && episodeNumber != nil else { throw ActionError.invalidShape }
        case "movie", "tv":
            guard seasonNumber == nil && episodeNumber == nil else { throw ActionError.invalidShape }
        default:
            throw ActionError.invalidShape
        }
    }

    /// La tabella non ha id sintetico: il `recordId` dell'outbox è la chiave naturale in chiaro.
    /// Il server non lo legge (usa il record); serve all'outbox per raggruppare e ai log.
    private func recordKey(mediaType: String, tmdbId: Int,
                           seasonNumber: Int?, episodeNumber: Int?) -> String {
        "\(mediaType):\(tmdbId):\(seasonNumber ?? -1):\(episodeNumber ?? -1)"
    }
}
