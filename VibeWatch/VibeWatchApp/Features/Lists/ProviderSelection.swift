import Foundation

/// Pure watch-provider selection logic extracted from `ListsView`.
///
/// Picks the single "top" provider to surface for an item, following the priority
/// Flatrate > Rent > Buy and taking the first *valid* provider in each tier. A provider
/// is valid when it has a usable logo and is actually reachable (has an external link,
/// or the country page has a link, or a known platform homepage exists).
///
/// Extracted verbatim from `ListsView.processProviders`/`isValid` (Fase 5 file-splitting)
/// so the selection can be unit-tested without a View. Behavior preserved: the region
/// `link` used in the validity check is the country page link, exactly as the original
/// set `providerLink = countryProviders.link` before validating.
enum ProviderSelection {

    /// Da quale scaffale viene il provider scelto. Serve alla pillola del Tracking, che etichetta
    /// l'azione ("Guarda su" / "Noleggia su" / "Acquista su") invece di mostrare solo il logo:
    /// noleggio e acquisto costano, e un'etichetta che non lo dice invita a un tap che delude.
    enum Tier {
        case flatrate
        case rent
        case buy
    }

    /// - Returns: the country page `link` and the chosen `top` provider (if any).
    ///   `top` is `nil` when no tier yields a valid provider — callers should preserve
    ///   any previously-shown provider in that case (matching the original behavior).
    static func selectTopProvider(from countryProviders: CountryProviders) -> (link: String?, top: Provider?) {
        let result = selectTopProviderWithTier(from: countryProviders)
        return (result.link, result.top)
    }

    /// Come sopra, ma dice anche da quale scaffale: Flatrate > Rent > Buy, il primo valido.
    static func selectTopProviderWithTier(
        from countryProviders: CountryProviders
    ) -> (link: String?, top: Provider?, tier: Tier?) {
        let link = countryProviders.link

        func isValid(_ provider: Provider) -> Bool {
            guard provider.hasUsableLogo else { return false }
            if provider.externalLink != nil || link != nil { return true }
            return PlatformDeepLinkHelper.hasPlatformHomepage(for: provider)
        }

        if let top = countryProviders.flatrate?.first(where: isValid) {
            return (link, top, .flatrate)
        }
        if let top = countryProviders.rent?.first(where: isValid) {
            return (link, top, .rent)
        }
        if let top = countryProviders.buy?.first(where: isValid) {
            return (link, top, .buy)
        }
        return (link, nil, nil)
    }
}
