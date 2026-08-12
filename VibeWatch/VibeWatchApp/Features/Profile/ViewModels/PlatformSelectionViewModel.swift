import Foundation
import SwiftUI

/// Il modello della schermata Piattaforme.
///
/// **Perché non basta l'enum.** `StreamingPlatform` è una lista di 30 nomi scritti a mano: non ha
/// i loghi (12 asset su 30), non sa cosa esiste nel paese dell'utente e invecchia da sola. Qui
/// l'elenco viene da TMDB — la stessa fonte dei loghi che le card già mostrano — e i numeri
/// ("quanti titoli della tua libreria stanno su Netflix") dalla cache `watch_providers` che l'app
/// riempie comunque.
@MainActor
final class PlatformSelectionViewModel: ObservableObject {

    enum Tier: String, CaseIterable, Identifiable {
        case streaming, rent, buy
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .streaming: return "platforms.streaming"
            case .rent: return "platforms.rent"
            case .buy: return "platforms.buy"
            }
        }
    }

    @Published private(set) var providers: [Provider] = []
    /// providerId → quanti titoli della libreria sono disponibili lì.
    @Published private(set) var libraryCounts: [Int: Int] = [:]
    @Published private(set) var tierProviderIds: [Tier: Set<Int>] = [:]
    /// Percentuale di watchlist coperta dalle piattaforme scelte. `nil` quando i dati in cache
    /// non bastano: un numero costruito su un terzo dei titoli è peggio di nessun numero.
    @Published private(set) var coverage: Double?
    @Published private(set) var isLoading = false

    private let tmdb: any TMDBServiceProtocol
    private let db: SQLiteService
    private let region: () -> String

    /// Sotto questa quota di titoli con dati provider in cache, la percentuale non si mostra.
    private static let minimumCoverageSample = 0.5

    init(
        tmdb: any TMDBServiceProtocol = BudgetedTMDBService(wrapping: TMDBService.shared),
        db: SQLiteService = .shared,
        region: @escaping () -> String = { LocalizationManager.shared.currentCountry.id }
    ) {
        self.tmdb = tmdb
        self.db = db
        self.region = region
    }

    // MARK: - Caricamento

    func load(selected: Set<Int>) async {
        isLoading = true
        defer { isLoading = false }

        let region = region()
        await loadCatalog(region: region)
        await loadLibrarySignals(region: region, selected: selected)
    }

    /// Ricalcola solo ciò che dipende dalla selezione (la copertura), senza rifare la rete.
    func refreshCoverage(selected: Set<Int>) async {
        await loadLibrarySignals(region: region(), selected: selected)
    }

    private func loadCatalog(region: String) async {
        async let movies = try? tmdb.getAvailableWatchProviders(mediaType: "movie", region: region)
        async let shows = try? tmdb.getAvailableWatchProviders(mediaType: "tv", region: region)

        let merged = ((await movies) ?? []) + ((await shows) ?? [])
        guard !merged.isEmpty else { return }

        // Dedup per provider_id: film e serie condividono quasi tutti i servizi.
        var byId: [Int: Provider] = [:]
        for provider in merged where byId[provider.providerId] == nil {
            byId[provider.providerId] = provider
        }
        providers = Array(byId.values)
    }

    /// Conteggi per provider, appartenenza ai tier e copertura: tutto dalla cache locale.
    private func loadLibrarySignals(region: String, selected: Set<Int>) async {
        let library = await libraryMedia()
        guard !library.isEmpty else {
            libraryCounts = [:]
            coverage = nil
            return
        }

        var counts: [Int: Int] = [:]
        var tiers: [Tier: Set<Int>] = [:]
        var watchlistWithData = 0
        var watchlistCovered = 0

        for media in library {
            guard let providers = await cachedProviders(
                mediaId: media.id, mediaType: media.type, region: region
            ) else { continue }

            let flatrate = providers.flatrate ?? []
            let rent = providers.rent ?? []
            let buy = providers.buy ?? []

            for provider in flatrate { tiers[.streaming, default: []].insert(provider.providerId) }
            for provider in rent { tiers[.rent, default: []].insert(provider.providerId) }
            for provider in buy { tiers[.buy, default: []].insert(provider.providerId) }

            let ids = Set((flatrate + rent + buy).map(\.providerId))
            for id in ids { counts[id, default: 0] += 1 }

            if media.inWatchlist {
                watchlistWithData += 1
                if !ids.isDisjoint(with: selected) { watchlistCovered += 1 }
            }
        }

        libraryCounts = counts
        tierProviderIds = tiers

        let watchlistTotal = library.filter(\.inWatchlist).count
        if watchlistTotal > 0,
           Double(watchlistWithData) / Double(watchlistTotal) >= Self.minimumCoverageSample,
           watchlistWithData > 0 {
            coverage = Double(watchlistCovered) / Double(watchlistWithData)
        } else {
            coverage = nil
        }
    }

    // MARK: - Lettura della libreria

    private struct LibraryMedia {
        let id: Int
        let type: MediaType
        let inWatchlist: Bool
    }

    private func libraryMedia() async -> [LibraryMedia] {
        let rows = (try? await db.queryRaw(
            """
            SELECT li.media_id AS media_id, li.media_type AS media_type, l.type AS list_type
              FROM list_items li
              JOIN lists l ON l.id = li.list_id
             WHERE li.deleted_at IS NULL AND l.deleted_at IS NULL
            """,
            parameters: []
        )) ?? []

        var byKey: [String: LibraryMedia] = [:]
        for row in rows {
            guard let id = (row["media_id"] as? Int64).map(Int.init) ?? row["media_id"] as? Int,
                  let typeRaw = row["media_type"] as? String,
                  let type = MediaType(rawValue: typeRaw) else { continue }
            let key = "\(typeRaw):\(id)"
            let inWatchlist = (row["list_type"] as? String) == ListType.watchlist.rawValue
            if let existing = byKey[key] {
                byKey[key] = LibraryMedia(id: id, type: type,
                                          inWatchlist: existing.inWatchlist || inWatchlist)
            } else {
                byKey[key] = LibraryMedia(id: id, type: type, inWatchlist: inWatchlist)
            }
        }

        // Le serie seguite non hanno righe `list_items`: stanno nello specchio del tracking.
        let trackingRows = (try? await db.queryRaw(
            """
            SELECT tmdb_show_id, bucket FROM tv_tracking
             WHERE bucket IN ('not_started', 'for_later', 'up_next', 'stale', 'up_to_date')
            """,
            parameters: []
        )) ?? []

        for row in trackingRows {
            guard let id = (row["tmdb_show_id"] as? Int64).map(Int.init) ?? row["tmdb_show_id"] as? Int
            else { continue }
            let key = "tv:\(id)"
            let inWatchlist = (row["bucket"] as? String) != "up_to_date"
            if let existing = byKey[key] {
                byKey[key] = LibraryMedia(id: id, type: .tv,
                                          inWatchlist: existing.inWatchlist || inWatchlist)
            } else {
                byKey[key] = LibraryMedia(id: id, type: .tv, inWatchlist: inWatchlist)
            }
        }

        return Array(byKey.values)
    }

    private func cachedProviders(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders? {
        // Senza filtro sul TTL: qui si contano titoli, non si decide cosa mostrare come "guarda
        // ora". Una riga scaduta di un giorno è comunque il dato migliore che abbiamo.
        guard let rows = try? await db.queryRaw(
            """
            SELECT providers_json FROM watch_providers
             WHERE media_id = ? AND media_type = ? AND region = ?
            """,
            parameters: [mediaId, mediaType.rawValue, region]
        ),
        let json = rows.first?["providers_json"] as? String,
        let data = Data(base64Encoded: json),
        let decoded = try? JSONDecoder().decode(CountryProviders.self, from: data)
        else { return nil }
        return decoded
    }

    // MARK: - Ordinamento e presentazione

    /// I provider di un tier, ordinati: prima i selezionati, poi per titoli in libreria, poi per
    /// la priorità che TMDB dà a quel servizio nella regione.
    func providers(for tier: Tier, selected: Set<Int>) -> [Provider] {
        let tierIds = tierProviderIds[tier] ?? []
        // Lo streaming è l'elenco completo; per noleggio e acquisto TMDB non distingue i tier
        // nell'endpoint elenco, quindi si usa ciò che i dati in cache dicono davvero. Se la cache
        // non sa ancora niente, meglio l'elenco intero di una schermata vuota.
        let base: [Provider]
        if tier == .streaming || tierIds.isEmpty {
            base = providers
        } else {
            base = providers.filter { tierIds.contains($0.providerId) }
        }

        return base.sorted { lhs, rhs in
            let lSel = selected.contains(lhs.providerId)
            let rSel = selected.contains(rhs.providerId)
            if lSel != rSel { return lSel }

            let lCount = libraryCounts[lhs.providerId] ?? 0
            let rCount = libraryCounts[rhs.providerId] ?? 0
            if lCount != rCount { return lCount > rCount }

            if lhs.displayPriority != rhs.displayPriority { return lhs.displayPriority < rhs.displayPriority }
            return lhs.providerName < rhs.providerName
        }
    }

    /// Il provider da consigliare: quello NON selezionato con più titoli in libreria.
    func recommendedProviderId(selected: Set<Int>) -> Int? {
        providers
            .filter { !selected.contains($0.providerId) }
            .compactMap { provider -> (Int, Int)? in
                guard let count = libraryCounts[provider.providerId], count > 0 else { return nil }
                return (provider.providerId, count)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    func activeCount(for tier: Tier, selected: Set<Int>) -> Int {
        guard tier != .streaming else { return selected.count }
        let ids = tierProviderIds[tier] ?? []
        return ids.isEmpty ? selected.count : selected.intersection(ids).count
    }

    // MARK: - Migrazione dalla vecchia selezione

    /// Traduce una volta sola la vecchia selezione (nomi scritti a mano) in provider_id TMDB.
    ///
    /// Il confronto è per nome, senza maiuscole: hardcodare gli id TMDB dei 30 casi sarebbe una
    /// seconda tabella da tenere aggiornata, ed è esattamente ciò da cui questa schermata scappa.
    func migratedIds(from platforms: Set<StreamingPlatform>) -> Set<Int> {
        var ids: Set<Int> = []
        for platform in platforms {
            let needle = platform.rawValue.lowercased()
            let match = providers.first { provider in
                let name = provider.providerName.lowercased()
                return name == needle || name.contains(needle) || needle.contains(name)
            }
            if let match { ids.insert(match.providerId) }
        }
        return ids
    }
}

/// Persistenza della selezione: `Set<Int>` JSON in `@AppStorage`.
///
/// Accanto agli id si salvano anche i **nomi**: il filtro di disponibilità (`ListAvailabilityService`,
/// `GlobalFilterView`) confronta i provider per nome, e senza i nomi la scelta dell'utente non
/// arriverebbe fin lì. Gli id restano l'identità; i nomi sono la copia che serve altrove.
enum ProviderSelectionCodec {
    static func decode(_ data: Data) -> Set<Int> {
        guard !data.isEmpty,
              let ids = try? JSONDecoder().decode(Set<Int>.self, from: data) else { return [] }
        return ids
    }

    static func encode(_ ids: Set<Int>) -> Data {
        (try? JSONEncoder().encode(ids)) ?? Data()
    }

    static func decodeNames(_ data: Data) -> Set<String> {
        guard !data.isEmpty,
              let names = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return names
    }

    static func encodeNames(_ names: Set<String>) -> Data {
        (try? JSONEncoder().encode(names)) ?? Data()
    }
}
