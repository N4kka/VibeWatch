import XCTest
@testable import VibeWatchApp

/// Unit tests for the launch-time configuration check.
///
/// I casi non sono inventati: sono esattamente le due forme in cui la configurazione si è rotta su
/// questa macchina il 2026-07-31, e che avevano portato a sospettare prima il codice di sync, poi
/// la rete.
final class ConfigValidationTests: XCTestCase {

    private func entry(_ key: String, _ value: String, isURL: Bool = false) -> Config.Entry {
        Config.Entry(key, value, isURL: isURL)
    }

    // MARK: - Configurazione sana

    func testConfigurazioneCompletaNonHaProblemi() {
        let problemi = Config.problems(in: [
            entry("TMDB_API_KEY", "0123456789abcdef0123456789abcdef"),
            entry("SUPABASE_URL", "https://abc.supabase.co", isURL: true),
            entry("APP_STORE_URL", "https://apps.apple.com/app/id123", isURL: true)
        ])

        XCTAssertTrue(problemi.isEmpty)
    }

    // MARK: - Chiavi mancanti

    func testChiaveVuotaEUnProblema() {
        let problemi = Config.problems(in: [entry("TMDB_API_KEY", "")])

        XCTAssertEqual(problemi, [.missing(key: "TMDB_API_KEY")])
    }

    /// Un valore di soli spazi passa un controllo `isEmpty` ma non serve a niente.
    func testChiaveDiSoliSpaziEUnProblema() {
        let problemi = Config.problems(in: [entry("SUPABASE_ANON_KEY", "   ")])

        XCTAssertEqual(problemi, [.missing(key: "SUPABASE_ANON_KEY")])
    }

    func testOgniChiaveMancanteVieneElencata() {
        let problemi = Config.problems(in: [
            entry("TMDB_API_KEY", ""),
            entry("SUPABASE_ANON_KEY", ""),
            entry("REVENUECAT_API_KEY", "ok")
        ])

        XCTAssertEqual(problemi.count, 2, "l'elenco serve a sistemarle tutte in un giro solo")
        XCTAssertEqual(problemi, [.missing(key: "TMDB_API_KEY"), .missing(key: "SUPABASE_ANON_KEY")])
    }

    // MARK: - URL troncati

    /// La regressione vera: `https:$()//host` in xcconfig viene troncato a `https:` perché il
    /// parser toglie i commenti prima di espandere le variabili. Il valore non è vuoto, quindi un
    /// controllo di sola presenza lo lascia passare, e ogni chiamata al backend parte verso un URL
    /// inutilizzabile.
    func testUrlTroncatoASoloSchemaEUnProblema() {
        let problemi = Config.problems(in: [entry("SUPABASE_URL", "https:", isURL: true)])

        XCTAssertEqual(problemi, [.malformedURL(key: "SUPABASE_URL", value: "https:")])
    }

    func testUrlSenzaHostEUnProblema() {
        let problemi = Config.problems(in: [entry("POSTHOG_HOST", "https://", isURL: true)])

        XCTAssertEqual(problemi.count, 1)
    }

    func testUrlNonHttpsEUnProblema() {
        let problemi = Config.problems(in: [entry("UPDATE_CONFIG_URL", "http://esempio.it", isURL: true)])

        XCTAssertEqual(problemi, [.malformedURL(key: "UPDATE_CONFIG_URL", value: "http://esempio.it")])
    }

    /// Una chiave non-URL non viene giudicata come URL: le API key non lo sono.
    func testChiaveNonUrlNonVieneValidataComeUrl() {
        let problemi = Config.problems(in: [entry("TMDB_API_KEY", "0123456789abcdef")])

        XCTAssertTrue(problemi.isEmpty)
    }

    // MARK: - Descrizioni

    func testLeDescrizioniNominanoLaChiave() {
        XCTAssertTrue(Config.Problem.missing(key: "TMDB_API_KEY").description.contains("TMDB_API_KEY"))
        XCTAssertTrue(Config.Problem.malformedURL(key: "SUPABASE_URL", value: "https:")
            .description.contains("SUPABASE_URL"))
    }

    // MARK: - Il bundle reale

    /// Non asserisce che la configurazione sia completa — su una macchina senza segreti fallirebbe
    /// per una ragione che non è un bug del codice. Verifica solo che l'elenco delle chiavi da
    /// controllare non si svuoti per una svista in un refactor.
    func testIlBundleDichiaraLeChiaviAttese() {
        let chiavi = Config.entries.map(\.key)

        XCTAssertEqual(chiavi.count, 8)
        XCTAssertTrue(chiavi.contains("TMDB_API_KEY"))
        XCTAssertTrue(chiavi.contains("SUPABASE_URL"))
        XCTAssertFalse(chiavi.contains("RAPIDAPI_KEY"), "rimossa dal bundle, sta dietro a watch-providers")
        XCTAssertFalse(chiavi.contains("YOUTUBE_API_KEY"), "rimossa dal bundle, sta dietro a youtube-search")
    }
}
