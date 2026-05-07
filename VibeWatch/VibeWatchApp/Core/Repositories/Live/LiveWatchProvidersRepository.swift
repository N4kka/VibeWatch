import Foundation

/// Fetches watch providers with a 24-hour SQLite cache.
/// This is the ONLY component allowed to call the providers network APIs at runtime
/// in DiscoveryView, ListsView, MovieDetailView, and TVShowDetailView.
@MainActor
final class LiveWatchProvidersRepository: WatchProvidersRepositoryProtocol {
    static let shared = LiveWatchProvidersRepository()
    private let local = LocalWatchProvidersRepository.shared
    private let tmdb: any TMDBServiceProtocol = TMDBService.shared
    private let streaming = StreamingAvailabilityService.shared
    private init() {}

    nonisolated func observeProviders(mediaId: Int, mediaType: MediaType, region: String) -> AsyncStream<CountryProviders?> {
        AsyncStream { continuation in
            Task { @MainActor in
                let cached = await self.local.cachedProviders(mediaId: mediaId, mediaType: mediaType, region: region)
                if let cached {
                    continuation.yield(cached)
                    continuation.finish()
                    return
                }
                // Cache miss or expired — fetch from network
                let fresh = await self.fetchAndMerge(mediaId: mediaId, mediaType: mediaType, region: region)
                if let fresh {
                    await self.local.save(fresh, mediaId: mediaId, mediaType: mediaType, region: region)
                }
                continuation.yield(fresh)
                continuation.finish()
            }
        }
    }

    nonisolated func providers(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders? {
        if let cached = await local.cachedProviders(mediaId: mediaId, mediaType: mediaType, region: region) {
            return cached
        }
        let fresh = await fetchAndMerge(mediaId: mediaId, mediaType: mediaType, region: region)
        if let fresh {
            await local.save(fresh, mediaId: mediaId, mediaType: mediaType, region: region)
        }
        return fresh
    }

    private func fetchAndMerge(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders? {
        do {
            var richProviders = try await streaming.getProviders(tmdbId: mediaId, type: mediaType, region: region)
            let tmdbResult: WatchProvider
            if mediaType == .movie {
                tmdbResult = try await tmdb.getMovieWatchProviders(id: mediaId)
            } else {
                tmdbResult = try await tmdb.getTVShowWatchProviders(id: mediaId)
            }
            if let basic = tmdbResult.results[region] {
                richProviders = merge(rich: richProviders, basic: basic)
            }
            return richProviders
        } catch {
            Logger.warning("[WatchProvidersRepo] Fetch failed for \(mediaId) (\(mediaType.rawValue)): \(error.localizedDescription)")
            return nil
        }
    }

    private func merge(rich: CountryProviders, basic: CountryProviders) -> CountryProviders {
        var merged = rich
        merged.flatrate = mergeList(rich.flatrate, basic.flatrate)
        merged.rent = mergeList(rich.rent, basic.rent)
        merged.buy = mergeList(rich.buy, basic.buy)
        merged.link = rich.link ?? basic.link
        return merged
    }

    private func mergeList(_ richList: [Provider]?, _ basicList: [Provider]?) -> [Provider]? {
        guard let basicList else { return richList }
        guard var richList else { return basicList }
        for provider in basicList {
            if let idx = richList.firstIndex(where: { namesMatch($0.providerName, provider.providerName) }) {
                let logo = richList[idx].logoPath.lowercased()
                if (logo.isEmpty || logo.contains(".svg")) && !provider.logoPath.isEmpty {
                    let existing = richList[idx]
                    richList[idx] = Provider(
                        providerId: existing.providerId,
                        providerName: existing.providerName,
                        logoPath: provider.logoPath,
                        displayPriority: existing.displayPriority,
                        price: existing.price,
                        quality: existing.quality,
                        presentationType: existing.presentationType,
                        externalLink: existing.externalLink
                    )
                }
            } else {
                richList.append(provider)
            }
        }
        return richList
    }

    private func namesMatch(_ a: String, _ b: String) -> Bool {
        let n: (String) -> String = { s in
            s.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "+", with: "plus")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "tv", with: "")
        }
        let na = n(a), nb = n(b)
        return na == nb || na.contains(nb) || nb.contains(na)
    }
}
