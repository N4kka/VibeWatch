import Foundation

/// Pure watch-provider tier grouping extracted from `MovieDetailView`.
enum WatchProviderTierGroupsBuilder {

    struct TierGroup: Equatable {
        let titleKey: String
        let providers: [Provider]
        let justWatchLink: String?
    }

    static func groups(in providers: CountryProviders) -> [TierGroup] {
        [
            tier(titleKey: "platforms.streaming", providers: providers.flatrate, justWatchLink: providers.link),
            tier(titleKey: "platforms.rent", providers: providers.rent, justWatchLink: providers.link),
            tier(titleKey: "platforms.buy", providers: providers.buy, justWatchLink: providers.link)
        ].compactMap { $0 }
    }

    private static func tier(titleKey: String, providers: [Provider]?, justWatchLink: String?) -> TierGroup? {
        let visibleProviders = WatchProviderDisplayFiltering.visibleProviders(providers, justWatchLink: justWatchLink)
        guard !visibleProviders.isEmpty else { return nil }
        return TierGroup(titleKey: titleKey, providers: visibleProviders, justWatchLink: justWatchLink)
    }
}
