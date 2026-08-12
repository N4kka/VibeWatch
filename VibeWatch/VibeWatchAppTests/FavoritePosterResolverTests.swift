import XCTest
@testable import VibeWatchApp

/// I preferiti del profilo comparivano minuti dopo perché ogni tile chiedeva a TMDB un dettaglio
/// intero, in coda dietro caroselli e prefetch. Il poster però è quasi sempre già sul telefono.
final class FavoritePosterResolverTests: XCTestCase {

    /// Uno specchio locale che risponde: la rete non deve nemmeno essere sfiorata.
    func testConIlPosterInLocaleNonSiChiamaLaRete() async {
        let reteChiamata = Contatore()
        let resolver = FavoritePosterResolver(
            cachedPosterPath: { _, _ in nil },
            storedPosterPath: { _, _ in "/locale.jpg" },
            remotePosterPath: { _, _ in
                reteChiamata.valore += 1
                return "/rete.jpg"
            }
        )

        let url = await resolver.posterURL(mediaType: "movie", tmdbId: 42)

        XCTAssertEqual(url?.absoluteString, "https://image.tmdb.org/t/p/w500/locale.jpg")
        XCTAssertEqual(reteChiamata.valore, 0, "la rete non va interrogata se il poster è in locale")
    }

    /// La cache dei dettagli viene prima dello specchio delle liste.
    func testLaCacheDeiDettagliHaLaPrecedenza() async {
        let resolver = FavoritePosterResolver(
            cachedPosterPath: { _, _ in "/cache.jpg" },
            storedPosterPath: { _, _ in "/locale.jpg" },
            remotePosterPath: { _, _ in "/rete.jpg" }
        )

        let path = await resolver.posterPath(mediaType: "tv", tmdbId: 7)

        XCTAssertEqual(path, "/cache.jpg")
    }

    /// Ultima spiaggia: se in locale non c'è niente, la rete resta l'unica strada.
    func testSenzaDatiLocaliSiPassaDallaRete() async {
        let resolver = FavoritePosterResolver(
            cachedPosterPath: { _, _ in nil },
            storedPosterPath: { _, _ in nil },
            remotePosterPath: { _, _ in "/rete.jpg" }
        )

        let path = await resolver.posterPath(mediaType: "tv", tmdbId: 7)

        XCTAssertEqual(path, "/rete.jpg")
    }

    /// Un percorso vuoto non è un poster: meglio il segnaposto di una URL rotta.
    func testIlPercorsoVuotoNonProduceUnaURL() async {
        let resolver = FavoritePosterResolver(
            cachedPosterPath: { _, _ in "" },
            storedPosterPath: { _, _ in nil },
            remotePosterPath: { _, _ in nil }
        )

        let url = await resolver.posterURL(mediaType: "movie", tmdbId: 1)

        XCTAssertNil(url)
    }

    private final class Contatore {
        var valore = 0
    }
}
