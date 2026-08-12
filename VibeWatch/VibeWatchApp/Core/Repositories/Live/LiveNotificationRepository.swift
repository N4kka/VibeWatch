import Foundation

@MainActor
final class LiveNotificationRepository: NotificationRepositoryProtocol {
    static let shared = LiveNotificationRepository()
    private init() {}

    func toggleAlert(mediaId: Int, mediaType: MediaType, enabled: Bool = true) async throws {
        guard let userId = AuthService.shared.currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }

        // Il paese è quello scelto nell'app, non quello del dispositivo: l'avviso dice "è uscito
        // dove guardi tu", e la disponibilità in tutto il resto dell'app si legge da qui.
        let region = LocalizationManager.shared.currentCountry.id

        // `release_alerts` NON ha una colonna `updated_at`: mandarla faceva rispondere a
        // PostgREST 400 (PGRST204, colonna sconosciuta) e "Avvisami" falliva sempre, a ogni tap.
        let record: [String: Any] = [
            "user_id": userId,
            "media_id": mediaId,
            "media_type": mediaType.rawValue,
            "source": "notify_me",
            "country_code": region,
            "is_active": enabled
        ]

        do {
            try await SupabaseService.shared.upsertRow(
                table: "release_alerts",
                onConflict: "user_id,media_id,media_type",
                record: record
            )
        } catch {
            // Il toast dice solo "non riuscito": senza questo, capire perché richiede un debugger.
            Logger.error("[Notifications] release_alerts upsert fallito: \(error)")
            throw error
        }
    }
}
