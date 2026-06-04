import Foundation

/// Pure display filtering for watch providers shown in movie detail screens.
///
/// A provider is visible when it has a usable raster logo and a reachable destination:
/// a direct external link, a JustWatch country page link, or a known platform homepage.
enum WatchProviderDisplayFiltering {

    static func visibleProviders(_ providers: [Provider]?, justWatchLink: String?) -> [Provider] {
        (providers ?? []).filter { isVisible($0, justWatchLink: justWatchLink) }
    }

    static func hasAnyVisibleProvider(in providers: CountryProviders) -> Bool {
        !visibleProviders(providers.flatrate, justWatchLink: providers.link).isEmpty ||
        !visibleProviders(providers.rent, justWatchLink: providers.link).isEmpty ||
        !visibleProviders(providers.buy, justWatchLink: providers.link).isEmpty
    }

    static func isVisible(_ provider: Provider, justWatchLink: String?) -> Bool {
        guard provider.hasUsableLogo else { return false }
        if provider.externalLink != nil || justWatchLink != nil { return true }
        return PlatformDeepLinkHelper.hasPlatformHomepage(for: provider)
    }
}
