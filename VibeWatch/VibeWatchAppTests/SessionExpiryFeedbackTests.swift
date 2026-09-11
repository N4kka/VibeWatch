import XCTest
@testable import VibeWatchApp

/// Cosa legge chi tappa "vista tutta" quando il server rifiuta la sessione.
///
/// Il caso che ha generato questi test, dai log del 25 agosto: un access token ancora integro la
/// cui sessione GoTrue era stata cancellata da un logout su un altro device. Il telefono non
/// aveva modo di accorgersene — `auth.session` restituiva il token cacheato e PostgREST lo
/// accettava — e "vista tutta" rispondeva, per un'ora buona,
/// `Supabase HTTP 401: {"error":"invalid_token"}` in un toast, sopra un dialogo che diceva
/// "An unexpected error occurred".
///
/// Due bugie in una schermata: non è un guasto imprevisto, ed è una cosa che l'utente può
/// risolvere in dieci secondi. Da qui in avanti la frase è quella giusta.
final class SessionExpiryFeedbackTests: XCTestCase {

    func testUnaSessioneScadutaDiceDiRifareLAccesso() {
        let atteso = "auth.error.sessionExpired".localized
        XCTAssertNotEqual(atteso, "auth.error.sessionExpired", "la chiave deve esistere in en.lproj")

        XCTAssertEqual(MarkShowSeen.message(for: SupabaseError.sessionExpired), atteso)
        XCTAssertEqual(MarkShowSeen.message(for: SupabaseError.notAuthenticated), atteso)
        XCTAssertEqual(MarkShowSeen.message(for: SupabaseError.authenticationFailed), atteso)
    }

    func testUnErroreDiReteRestaUnErroreDiRete() {
        XCTAssertEqual(
            MarkShowSeen.message(for: SupabaseError.networkError),
            "auth.error.networkError".localized)
    }

    /// Il corpo grezzo della risposta è diagnostica, non copy: non deve MAI finire in un toast
    /// quando la causa è una sessione da rifare.
    func testIlCorpoDellaRispostaNonFinisceSottoGliOcchiDellUtente() {
        let messaggio = MarkShowSeen.message(for: SupabaseError.sessionExpired)
        XCTAssertFalse(messaggio.contains("Supabase HTTP"))
        XCTAssertFalse(messaggio.contains("invalid_token"))
    }

    /// Gli errori che NON sono di sessione continuano a dire quello che dicevano: un 500 del
    /// catalogo non è "rifai l'accesso", e nasconderlo dietro una frase rassicurante sarebbe
    /// lo stesso difetto al contrario.
    func testUnErroreDiversoRestaSeStesso() {
        let http = SupabaseError.httpError(statusCode: 500, body: "boom")
        XCTAssertEqual(MarkShowSeen.message(for: http), http.localizedDescription)
    }
}
