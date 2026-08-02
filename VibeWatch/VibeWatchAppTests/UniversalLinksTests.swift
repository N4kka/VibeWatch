import XCTest
@testable import VibeWatchApp

/// SPEC v3 §9.4 — universal links: il parser delle rotte, l'aggancio ad AppNavigationManager,
/// e la coerenza fra `UniversalLinks.host` e ciò che sta scritto fuori dal codice (entitlement
/// e AASA). Il dominio è ancora un segnaposto: questi test sono ciò che rende sicuro cambiarlo
/// in un punto solo quando quello vero esisterà.
@MainActor
final class UniversalLinksTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        AppNavigationManager.shared.clearDeepLinkTarget()
        AppNavigationManager.shared.clearProfileLinkTarget()
    }

    override func tearDown() async throws {
        AppNavigationManager.shared.clearDeepLinkTarget()
        AppNavigationManager.shared.clearProfileLinkTarget()
        try await super.tearDown()
    }

    private func url(_ s: String) -> URL {
        guard let u = URL(string: s) else {
            XCTFail("URL di test non costruibile: \(s)")
            return URL(fileURLWithPath: "/")
        }
        return u
    }

    // MARK: - Parser: le rotte riconosciute

    func testProfiloValido() {
        let route = UniversalLinks.route(for: url("https://\(UniversalLinks.host)/@nakka"))
        XCTAssertEqual(route, .profile(username: "nakka"))
    }

    func testProfiloConMaiuscoleSiAbbassa() {
        // `username` è citext sul server: /@Nakka e /@nakka sono lo stesso profilo.
        let route = UniversalLinks.route(for: url("https://\(UniversalLinks.host)/@Nakka"))
        XCTAssertEqual(route, .profile(username: "nakka"))
    }

    func testProfiloConWww() {
        // Gli entitlement dichiarano anche www: un link con www può aprire l'app, quindi il
        // parser deve riconoscerlo — aprirsi e lasciar cadere il link sarebbe un guasto muto.
        let route = UniversalLinks.route(for: url("https://www.\(UniversalLinks.host)/@nakka"))
        XCTAssertEqual(route, .profile(username: "nakka"))
    }

    func testSottodominioQualunqueCade() {
        // Solo apex e www: gli altri sottodomini non stanno negli entitlement, e il parser non
        // deve essere più largo di ciò che gli entitlement promettono.
        XCTAssertNil(UniversalLinks.route(for: url("https://app.\(UniversalLinks.host)/@nakka")))
    }

    func testProfiloConTrailingSlash() {
        let route = UniversalLinks.route(for: url("https://\(UniversalLinks.host)/@nakka/"))
        XCTAssertEqual(route, .profile(username: "nakka"))
    }

    func testFilmValido() {
        let route = UniversalLinks.route(for: url("https://\(UniversalLinks.host)/film/27205"))
        XCTAssertEqual(route, .film(id: 27205))
    }

    func testProfileURLTornaAllaStessaRotta() {
        // `profileURL` è dichiarato inverso di `route(for:)` — il pulsante Condividi profilo
        // costruisce lì il suo link. Se uno dei due cambia forma, questo test lo dice.
        let url = UniversalLinks.profileURL(username: "nakka")
        XCTAssertEqual(UniversalLinks.route(for: url), .profile(username: "nakka"))
    }

    // MARK: - Parser: ciò che deve cadere

    func testHostSbagliatoCade() {
        XCTAssertNil(UniversalLinks.route(for: url("https://example.com/@nakka")))
    }

    func testHttpCade() {
        // http non è mai un universal link; accettarlo sarebbe fingere una garanzia che non c'è.
        XCTAssertNil(UniversalLinks.route(for: url("http://\(UniversalLinks.host)/@nakka")))
    }

    func testSchemeOAuthCade() {
        // L'URL del callback OAuth deve passare da handle(universalLink:) senza essere mangiato:
        // il ramo OAuth di onOpenURL viene dopo e deve vederlo intatto.
        XCTAssertNil(UniversalLinks.route(for: url("com.vibewatch.VibeWatchApp://auth?code=x")))
    }

    func testUsernameFuoriFormaCade() {
        // Stesse regole di UsernameRules: la forma sbagliata non diventa una navigazione.
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/@ab")),
                     "troppo corto")
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/@a23456789012345678901")),
                     "21 caratteri")
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/@mario.rossi")),
                     "carattere non ammesso")
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/@")),
                     "vuoto")
    }

    func testFilmFuoriFormaCade() {
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/film/abc")))
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/film/0")))
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/film/1/2")))
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/film")))
    }

    func testRotteSconosciuteCadono() {
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/")))
        XCTAssertNil(UniversalLinks.route(for: url("https://\(UniversalLinks.host)/serie/1399")),
                     "solo le rotte di §9.4: /serie non esiste finché la spec non la chiede")
    }

    // MARK: - AppNavigationManager

    func testLinkProfiloImpostaProfileLinkTarget() {
        let handled = AppNavigationManager.shared.handle(
            universalLink: url("https://\(UniversalLinks.host)/@nakka"))
        XCTAssertTrue(handled)
        XCTAssertEqual(AppNavigationManager.shared.profileLinkTarget?.username, "nakka")
        XCTAssertNil(AppNavigationManager.shared.deepLinkTarget,
                     "un link profilo non deve toccare la strada dei film")
    }

    func testLinkFilmImpostaDeepLinkTarget() {
        let handled = AppNavigationManager.shared.handle(
            universalLink: url("https://\(UniversalLinks.host)/film/550"))
        XCTAssertTrue(handled)
        XCTAssertEqual(AppNavigationManager.shared.deepLinkTarget?.mediaId, 550)
        XCTAssertEqual(AppNavigationManager.shared.deepLinkTarget?.mediaType, "movie")
        XCTAssertNil(AppNavigationManager.shared.profileLinkTarget)
    }

    func testLinkNonRiconosciutoNonToccaNiente() {
        // Il contratto su cui si regge onOpenURL: false = "non è roba mia", zero effetti,
        // e l'URL resta disponibile per il ramo OAuth.
        let handled = AppNavigationManager.shared.handle(
            universalLink: url("com.vibewatch.VibeWatchApp://auth?code=x"))
        XCTAssertFalse(handled)
        XCTAssertNil(AppNavigationManager.shared.profileLinkTarget)
        XCTAssertNil(AppNavigationManager.shared.deepLinkTarget)
    }

    func testClearProfileLinkTarget() {
        AppNavigationManager.shared.handle(
            universalLink: url("https://\(UniversalLinks.host)/@nakka"))
        AppNavigationManager.shared.clearProfileLinkTarget()
        XCTAssertNil(AppNavigationManager.shared.profileLinkTarget)
    }

    // MARK: - Coerenza col mondo fuori dal codice

    /// La radice del repo, derivata dal percorso di questo file: i test girano sul simulatore
    /// ma sulla stessa macchina, quindi i file del repo sono leggibili.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UniversalLinksTests.swift
            .deletingLastPathComponent()   // VibeWatchAppTests/
    }

    func testEntitlementsCombacianoConHost() throws {
        // La promessa "il dominio si cambia in un punto solo" regge solo se qualcosa rompe
        // quando i punti fuori dal codice restano indietro. Questo test è quel qualcosa.
        for name in ["VibeWatchApp/VibeWatchApp.entitlements",
                     "VibeWatchApp/VibeWatchAppRelease.entitlements"] {
            let content = try String(contentsOf: repoRoot.appendingPathComponent(name),
                                     encoding: .utf8)
            // Apex E www, perché il parser accetta entrambi: se un entitlement ne perde uno,
            // metà dei link smette di aprire l'app e nessuno se ne accorge da un log.
            for entry in ["applinks:\(UniversalLinks.host)",
                          "applinks:www.\(UniversalLinks.host)"] {
                XCTAssertTrue(content.contains("<string>\(entry)</string>"),
                              "\(name) non contiene \(entry) — " +
                              "UniversalLinks.host e gli entitlement devono cambiare insieme")
            }
        }
    }

    func testAASACopreLeRotteEGliAppID() throws {
        let path = repoRoot.appendingPathComponent("docs/universal-links/apple-app-site-association")
        let data = try Data(contentsOf: path)
        // Prima di tutto: dev'essere JSON valido, perché Apple lo rifiuta intero altrimenti.
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertNotNil(json)
        let content = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(content.contains("/@*"), "manca il percorso dei profili")
        XCTAssertTrue(content.contains("/film/*"), "manca il percorso dei film")
        XCTAssertTrue(content.contains("3V97GU3CCY.com.vibewatch.VibeWatchApp"),
                      "manca l'appID di produzione")
        XCTAssertTrue(content.contains("3V97GU3CCY.com.vibewatch.VibeWatchApp.beta"),
                      "manca l'appID beta")
    }
}
