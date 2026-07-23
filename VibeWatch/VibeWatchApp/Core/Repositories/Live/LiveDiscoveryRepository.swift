import Foundation

/// Stale-while-revalidate discovery carousels.
/// Always emits any cached data (stale or fresh) immediately for instant paint, then
/// regenerates from TMDB in the background when the cache is expired or a force-refresh
/// is requested. Callers animate every emission after the first.
///
/// La rigenerazione emette in modo **incrementale**: l'hero appena pronto, poi un'emissione per
/// ogni batch completato, infine il risultato definitivo. Misurata a freddo, la generazione
/// completa costa ~5 s in ~4 ondate sequenziali di latenza TMDB; senza le parziali l'utente
/// aspettava tutte e quattro prima di vedere qualcosa. Al primo install (nessuna cache da
/// dipingere) è esattamente lo scenario peggiore, ed è quello che questo risolve.
@MainActor
final class LiveDiscoveryRepository: DiscoveryRepositoryProtocol {
    static let shared = LiveDiscoveryRepository()
    private let service = DiscoveryPersonalizationService.shared
    private init() {}

    nonisolated func observeCarousels(
        userId: String?,
        profile: UserProfile,
        filters: GlobalDiscoveryFilters,
        forceRefresh: Bool
    ) -> AsyncStream<[PersonalizedCarousel]> {
        AsyncStream { continuation in
            Task { @MainActor in
                // Emission 1: any cached data, stale or fresh — instant paint
                let anyCache = await self.service.loadAnyCachedCarouselsIfAvailable(userId: userId)
                if let anyCache {
                    continuation.yield(anyCache)
                }

                // Refresh when: explicit force, no cache at all, or cache is past expiry
                let shouldRefresh: Bool
                if forceRefresh || anyCache == nil {
                    shouldRefresh = true
                } else {
                    shouldRefresh = await self.service.isCacheStale(userId: userId)
                }

                if shouldRefresh {
                    // Emissioni 2…N: i caroselli man mano che i batch si completano, poi il
                    // risultato finale (l'unico con le logline dinamiche applicate).
                    if let fresh = try? await self.service.generatePersonalizedCarousels(
                        userProfile: profile,
                        filters: filters,
                        forceRefresh: true,
                        onPartialResults: { partial in
                            continuation.yield(partial)
                        }
                    ) {
                        continuation.yield(fresh)
                    }
                }

                continuation.finish()
            }
        }
    }
}
