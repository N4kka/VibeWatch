import Foundation

/// Sorgente read-only del feed attività (pipeline separata dall'offline-first: le righe le
/// compone il server, il client le mostra). Iniettabile per testare i ViewModel senza rete.
@MainActor
protocol ActivityFeedProviding {
    /// Feed paginato keyset: `before` è (occurred_at, activity_id) dell'ultima riga mostrata,
    /// nil per la prima pagina. `userId` è obbligatorio con scope `.user`.
    func fetchFeed(scope: ActivityFeedScope, userId: UUID?, before: (Date, UUID)?, limit: Int) async throws -> [ActivityItem]
    /// Opt-out (e rientro) dal feed della community.
    func setActivityFeedVisibility(_ enabled: Bool) async throws
}

/// Implementazione che delega a `SupabaseService`, con una rete sotto: la PRIMA pagina di ogni
/// scope resta in `activity_feed_cache`, così offline il feed mostra l'ultima fotografia invece
/// di un errore. Solo la prima pagina: la paginazione keyset ha senso solo contro il server —
/// una "pagina due" locale sarebbe una continuazione inventata di un cursore che non esiste più.
@MainActor
final class ActivityFeedRepository: ActivityFeedProviding {
    private let remote: SupabaseService
    private let sqlite: SQLiteService

    init(remote: SupabaseService = .shared, sqlite: SQLiteService = .shared) {
        self.remote = remote
        self.sqlite = sqlite
    }

    func fetchFeed(scope: ActivityFeedScope, userId: UUID?,
                   before: (Date, UUID)?, limit: Int) async throws -> [ActivityItem] {
        do {
            let items = try await remote.fetchActivityFeed(
                scope: scope, userId: userId, before: before, limit: limit)
            if before == nil {
                await cacheFirstPage(items, scope: scope)
            }
            return items
        } catch {
            // Offline o RPC fallita: la prima pagina risponde dalla cache, le successive no —
            // meglio fermare la paginazione che incollare righe stantie a un cursore vivo.
            if before == nil {
                let cached = await cachedFirstPage(scope: scope)
                if !cached.isEmpty {
                    Logger.warning("[ActivityFeed] Fetch failed, serving \(cached.count) cached rows for \(scope.rawValue): \(error.localizedDescription)")
                    return cached
                }
            }
            throw error
        }
    }

    func setActivityFeedVisibility(_ enabled: Bool) async throws {
        try await remote.setActivityFeedVisibility(enabled)
    }

    // MARK: - Cache (activity_feed_cache)

    /// La riga viaggia com'è (JSON dell'`ActivityItem`): la cache è una fotografia della
    /// risposta, non un secondo schema da tenere allineato colonna per colonna.
    private func cacheFirstPage(_ items: [ActivityItem], scope: ActivityFeedScope) async {
        do {
            // La fotografia si sostituisce intera: una card sparita dal server (attività
            // cancellata, autore bloccato) deve sparire anche da qui.
            try await sqlite.executeWrite(
                "DELETE FROM activity_feed_cache WHERE scope = ?", parameters: [scope.rawValue])
            guard !items.isEmpty else { return }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, enc in
                var container = enc.singleValueContainer()
                try container.encode(Self.cacheDateFormatter.string(from: date))
            }
            let rows: [[String: Any]] = try items.enumerated().compactMap { index, item in
                guard let json = String(data: try encoder.encode(item), encoding: .utf8) else {
                    return nil
                }
                return [
                    "scope": scope.rawValue,
                    "activity_id": item.id.uuidString.lowercased(),
                    "position": index,
                    "payload_json": json,
                ]
            }
            try await sqlite.upsert(table: "activity_feed_cache", rows: rows)
        } catch {
            // La cache è un comfort, non un dato: un fallimento qui non deve rompere il feed.
            Logger.warning("[ActivityFeed] Failed to cache feed page: \(error.localizedDescription)")
        }
    }

    private func cachedFirstPage(scope: ActivityFeedScope) async -> [ActivityItem] {
        let rows = (try? await sqlite.queryRaw(
            "SELECT payload_json FROM activity_feed_cache WHERE scope = ? ORDER BY position ASC",
            parameters: [scope.rawValue]
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.cacheDateFormatter.date(from: raw)
                ?? Self.cacheDateFallbackFormatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unparseable date: \(raw)")
        }
        // Una riga illeggibile si scarta, non rompe la pagina: la cache è rigenerabile
        // per costruzione al primo fetch riuscito.
        return rows.compactMap { row in
            guard let json = row["payload_json"] as? String,
                  let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(ActivityItem.self, from: data)
        }
    }

    /// Con i frazionali: `occurred_at` ha i microsecondi del server e troncare ai secondi
    /// farebbe collassare card vicine sullo stesso istante.
    private static let cacheDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Il ripiego senza frazionali: righe scritte da una versione che li ometteva.
    private static let cacheDateFallbackFormatter = ISO8601DateFormatter()
}
