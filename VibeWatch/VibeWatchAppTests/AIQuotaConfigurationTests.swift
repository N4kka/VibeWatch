import XCTest
@testable import VibeWatchApp

final class AIQuotaConfigurationTests: XCTestCase {
    func testChatbotDailyRequestLimitsMatchProductTiers() {
        XCTAssertEqual(AppConstants.AI.freeDailyRequestLimit, 8)
        XCTAssertEqual(AppConstants.AI.proDailyRequestLimit, 20)
    }

    /// "Il servizio e' spento" e "hai finito le tue richieste" non sono la stessa cosa e non
    /// possono leggersi uguale.
    ///
    /// Il caso vero: la quota dell'account Cerebras si e' esaurita e ogni richiesta tornava 402.
    /// `cerebras-proxy` appiattiva qualunque errore a monte su 502, e il client — che tratta 402 e
    /// 429 insieme — avrebbe detto "hai raggiunto il limite giornaliero, torna domani" a chi non
    /// aveva speso una singola richiesta, per un guasto che domani sarebbe stato identico.
    func testIlServizioSpentoNonSiLeggeComeUnLimiteDellUtente() {
        let spento = "ai.serviceUnavailable".localized
        XCTAssertNotEqual(spento, "ai.serviceUnavailable", "la chiave deve esistere in en.lproj")

        let limiteUtente = "ai.hardLimitMessage".localized
        XCTAssertNotEqual(spento, limiteUtente)

        // Non deve promettere una mezzanotte che non risolve niente, ne' incolpare l'utente.
        XCTAssertFalse(spento.lowercased().contains("limit"))
        XCTAssertFalse(spento.lowercased().contains("tomorrow"))
    }
}
