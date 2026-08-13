import Foundation

/// "Questo utente ha acceso il feed?", letto dallo specchio locale di `profiles` (zero rete: il
/// pull ci scrive `activity_feed_enabled` e `feed_activated_at` insieme al resto del profilo).
///
/// Serve a decidere i default che riguardano la visibilità — oggi il toggle "lista pubblica" su
/// una lista nuova. La domanda è deliberatamente stretta: **ha risposto E ha detto di sì.** Chi
/// ha risposto "resto privato", o chi l'annuncio non l'ha ancora visto, non deve trovarsi
/// interruttori di pubblicazione già alzati — sarebbe esattamente il dark pattern che
/// `FeedAnnouncementView` è stata scritta per evitare.
@MainActor
enum SocialFeedConsent {

    static func isFeedActive() async -> Bool {
        guard let userId = SupabaseService.shared.currentUser?.id else { return false }
        let rows = (try? await SQLiteService.shared.queryRaw(
            "SELECT activity_feed_enabled, feed_activated_at FROM profiles WHERE id = ?",
            parameters: [userId])) ?? []
        guard let row = rows.first else { return false }

        // Nessun timbro = annuncio mai risposto. Il flag da solo non basta: nasce a true sul
        // server per default, e leggerlo come consenso vorrebbe dire dare per data una risposta
        // che l'utente non ha ancora dato.
        guard let stamp = row["feed_activated_at"] as? String, !stamp.isEmpty else { return false }

        guard let raw = row["activity_feed_enabled"] else { return false }
        return (raw as? Int64).map { $0 != 0 }
            ?? (raw as? Int).map { $0 != 0 }
            ?? false
    }
}
