import XCTest
@testable import VibeWatchApp

/// La pagina di aggiornamento forzato prende i testi da un JSON remoto, e quel JSON **non** passa
/// da `.localized`: prima veniva mostrato verbatim, quindi la schermata era per metà nella lingua
/// dell'utente (badge, "COSA CAMBIA", bottone) e per metà in quella in cui era stato scritto il
/// file — inglese per tutti.
///
/// Qui si fissa il blocco `translations` che chiude quel buco, e soprattutto i suoi ripieghi: è
/// una schermata che l'utente non può chiudere, quindi un campo vuoto o una lingua sbagliata non
/// hanno una via d'uscita.
final class UpdateConfigLocalizationTests: XCTestCase {

    private typealias Config = UpdateCheckService.UpdateConfig

    private func config(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    private let completo = """
    {
      "minimum_version": "2.7",
      "title": "A brand-new VibeWatch",
      "message": "Everything has been redesigned.",
      "release_notes": ["One home\\nDiscover and Clips together."],
      "translations": {
        "it": {
          "title": "Un VibeWatch nuovo",
          "message": "Tutto ridisegnato.",
          "release_notes": ["Una casa sola\\nScopri e Clip insieme."]
        },
        "pt-BR": { "title": "Um novo VibeWatch" }
      }
    }
    """

    func test_laLinguaSceltaVinceSuiCampiInCima() throws {
        let testi = try config(completo).copy(for: "it")

        XCTAssertEqual(testi.title, "Un VibeWatch nuovo")
        XCTAssertEqual(testi.message, "Tutto ridisegnato.")
        XCTAssertEqual(testi.releaseNotes, ["Una casa sola\nScopri e Clip insieme."])
    }

    /// Senza una traduzione per quella lingua si mostra l'inglese: meglio una pagina in inglese
    /// che una pagina vuota da cui non si può uscire.
    func test_unaLinguaSenzaTraduzioneRicadeSuiCampiInCima() throws {
        let testi = try config(completo).copy(for: "ja")

        XCTAssertEqual(testi.title, "A brand-new VibeWatch")
        XCTAssertEqual(testi.message, "Everything has been redesigned.")
    }

    /// Il ripiego è per CAMPO, non per blocco: `pt-BR` porta solo il titolo, e il resto deve
    /// arrivare comunque — non sparire perché la traduzione era incompleta.
    func test_unaTraduzioneParzialePrendeIlRestoDallInglese() throws {
        let testi = try config(completo).copy(for: "pt-BR")

        XCTAssertEqual(testi.title, "Um novo VibeWatch")
        XCTAssertEqual(testi.message, "Everything has been redesigned.")
        XCTAssertEqual(testi.releaseNotes, ["One home\nDiscover and Clips together."])
    }

    /// Chi scrive il JSON non deve indovinare se l'app dirà "pt" o "pt-BR": si prova il codice
    /// pieno, poi la radice, poi qualunque variante con la stessa radice.
    func test_ilCodiceRegionaleEQuelloSempliceSiTrovanoAVicenda() throws {
        let solaRadice = try config("""
        { "minimum_version": "2.7", "title": "EN",
          "translations": { "it": { "title": "IT" } } }
        """)
        XCTAssertEqual(solaRadice.copy(for: "it-IT").title, "IT", "it-IT deve trovare it")

        let solaVariante = try config("""
        { "minimum_version": "2.7", "title": "EN",
          "translations": { "pt-BR": { "title": "PT" } } }
        """)
        XCTAssertEqual(solaVariante.copy(for: "pt").title, "PT", "pt deve trovare pt-BR")
    }

    /// Un JSON senza `translations` è quello che c'è in produzione oggi: deve continuare a
    /// funzionare esattamente come prima, altrimenti l'aggiunta romperebbe gli utenti attuali.
    func test_ilFormatoSenzaTraduzioniRestaValido() throws {
        let vecchio = try config("""
        { "minimum_version": "2.4", "latest_version": "2.5",
          "title": "A smarter VibeWatch is here",
          "message": "Your movie world is now fully connected.",
          "release_notes": ["Security & reliability improvements"],
          "app_store_url": "https://apps.apple.com/it/app/id6755368352" }
        """)

        let testi = vecchio.copy(for: "it")
        XCTAssertEqual(testi.title, "A smarter VibeWatch is here")
        XCTAssertEqual(testi.releaseNotes, ["Security & reliability improvements"])
        XCTAssertEqual(vecchio.minimumVersion, "2.4")
        XCTAssertEqual(vecchio.appStoreURL, "https://apps.apple.com/it/app/id6755368352")
    }

    /// Una lingua vuota non deve far saltare la ricerca nel dizionario.
    func test_unaLinguaVuotaNonRompeNiente() throws {
        XCTAssertEqual(try config(completo).copy(for: "").title, "A brand-new VibeWatch")
    }

    /// Il titolo di ripiego era la stringa inglese `"Update required"` scritta nel codice. Ora è
    /// una chiave, e deve esistere in tutte le lingue — se manca, `.localized` restituisce la
    /// chiave stessa e l'utente legge "update.fallbackTitle" a schermo.
    func test_ilTitoloDiRipiegoEUnaChiaveTradotta() {
        let risolto = "update.fallbackTitle".localized
        XCTAssertNotEqual(risolto, "update.fallbackTitle", "la chiave deve esistere in en.lproj")
        XCTAssertFalse(risolto.isEmpty)
    }
}
