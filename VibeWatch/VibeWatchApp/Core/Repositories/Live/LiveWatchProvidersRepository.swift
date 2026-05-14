import Foundation

protocol WatchProvidersCache {
    func cachedProviders(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders?
    func save(_ providers: CountryProviders, mediaId: Int, mediaType: MediaType, region: String) async
}

/// Fetches watch providers with a 24-hour SQLite cache.
/// This is the ONLY component allowed to call the providers network APIs at runtime
/// in DiscoveryView, ListsView, MovieDetailView, and TVShowDetailView.
@MainActor
final class LiveWatchProvidersRepository: WatchProvidersRepositoryProtocol {
    static let shared = LiveWatchProvidersRepository()
    private let local: any WatchProvidersCache
    private let tmdb: any TMDBWatchProvidersServiceProtocol
    private let streaming: any StreamingAvailabilityProviding

    init(
        local: any WatchProvidersCache = LocalWatchProvidersRepository.shared,
        tmdb: any TMDBWatchProvidersServiceProtocol = TMDBService.shared,
        streaming: any StreamingAvailabilityProviding = StreamingAvailabilityService.shared
    ) {
        self.local = local
        self.tmdb = tmdb
        self.streaming = streaming
    }

    nonisolated func observeProviders(mediaId: Int, mediaType: MediaType, region: String) -> AsyncStream<CountryProviders?> {
        AsyncStream { continuation in
            Task { @MainActor in
                let cached = await self.local.cachedProviders(mediaId: mediaId, mediaType: mediaType, region: region)
                if let cached, cached.hasUsableProviders {
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
        if let cached = await local.cachedProviders(mediaId: mediaId, mediaType: mediaType, region: region),
           cached.hasUsableProviders {
            return cached
        }
        let fresh = await fetchAndMerge(mediaId: mediaId, mediaType: mediaType, region: region)
        if let fresh {
            await local.save(fresh, mediaId: mediaId, mediaType: mediaType, region: region)
        }
        return fresh
    }

    private func fetchAndMerge(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders? {
        let richProviders: CountryProviders?
        do {
            richProviders = try await streaming.getProviders(tmdbId: mediaId, type: mediaType, region: region)
        } catch {
            richProviders = nil
            Logger.warning("[WatchProvidersRepo] Streaming fetch failed for \(mediaId) (\(mediaType.rawValue)): \(error.localizedDescription)")
        }

        let basicProviders: CountryProviders?
        do {
            let tmdbResult: WatchProvider
            if mediaType == .movie {
                tmdbResult = try await tmdb.getMovieWatchProviders(id: mediaId)
            } else {
                tmdbResult = try await tmdb.getTVShowWatchProviders(id: mediaId)
            }
            basicProviders = tmdbResult.results[region] ?? tmdbResult.results[region.uppercased()]
        } catch {
            basicProviders = nil
            Logger.warning("[WatchProvidersRepo] TMDB fetch failed for \(mediaId) (\(mediaType.rawValue)): \(error.localizedDescription)")
        }

        let merged: CountryProviders?
        switch (richProviders, basicProviders) {
        case let (rich?, basic?):
            merged = merge(rich: rich, basic: basic)
        case let (rich?, nil):
            merged = rich
        case let (nil, basic?):
            merged = basic
        case (nil, nil):
            merged = nil
        }

        guard let merged, merged.hasUsableProviders else { return nil }
        return merged
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
