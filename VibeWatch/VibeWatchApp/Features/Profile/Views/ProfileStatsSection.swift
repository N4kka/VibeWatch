import SwiftUI

/// SPEC v3 §9.3/§13.7 — lo stato delle stats di base, calcolate dal server.
///
/// I numeri arrivano da `get_my_stats`, **mai** da una somma locale: in cache c'è un anno di
/// eventi (§5) e il totale lo conosce solo il server. Tre stati distinti, mai schiacciati:
/// caricamento, numeri (gli zeri sono numeri veri, non un errore), e **fallimento con riprova**
/// — un errore di rete non si traveste da "non hai visto niente".
///
/// Le usa la dashboard in Impostazioni (deciso il 2026-08-01: un posto solo per le stats di
/// visione — la barra sul profilo doppiava la dashboard, e il suo tempo stimato a 30 min per
/// episodio da UserDefaults legacy è esattamente ciò che §13.7 vieta).
@MainActor
final class ProfileStatsViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(UserStats)
        case failed
    }

    @Published private(set) var phase: Phase = .loading

    private let fetch: () async throws -> UserStats

    init(fetch: @escaping () async throws -> UserStats = { try await SupabaseService.shared.myStats() }) {
        self.fetch = fetch
    }

    func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            phase = .loaded(try await fetch())
        } catch {
            phase = .failed
        }
    }
}
