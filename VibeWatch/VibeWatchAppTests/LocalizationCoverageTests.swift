import XCTest
@testable import VibeWatchApp

/// Le 20 lingue devono avere le stesse chiavi, e le chiavi che il codice chiede devono esistere.
///
/// **Perché serve un test e non una revisione.** Prima di questo giro i 18 file diversi da `en` e
/// `it` erano indietro di 24 chiavi — l'intera schermata Tracking — e due chiavi (`clips.noListsYet`,
/// `auth.error.invalidLink`) non esistevano in nessuna lingua: `.localized` restituisce la chiave
/// quando la traduzione manca, quindi sullo schermo compariva letteralmente
/// `auth.error.invalidLink`. Nessuno di questi difetti fa fallire un build.
///
/// I file si leggono dal sorgente, non dal bundle: quello che conta è che il repository sia
/// coerente, e un file dimenticato fuori dal target sparirebbe dal bundle senza far fallire niente.
final class LocalizationCoverageTests: XCTestCase {

    /// La lingua di riferimento: è quella su cui ricadono tutte le altre.
    private static let riferimento = "en"

    // MARK: - Lettura

    private static let cartella: URL = {
        URL(fileURLWithPath: #filePath)          // VibeWatchAppTests/LocalizationCoverageTests.swift
            .deletingLastPathComponent()          // VibeWatchAppTests/
            .deletingLastPathComponent()          // radice del progetto
            .appendingPathComponent("VibeWatchApp/Resources/Localization")
    }()

    /// `"chiave" = "valore";` — la stessa forma che accetta il caricatore di `.strings`.
    private static let riga = try! NSRegularExpression(
        pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$"#)

    private struct File {
        let lingua: String
        /// In ordine di apparizione, duplicati inclusi: servono a trovarli.
        let voci: [(chiave: String, valore: String)]
        var chiavi: Set<String> { Set(voci.map(\.chiave)) }
        var duplicate: [String] {
            var viste = Set<String>(), doppie = Set<String>()
            for v in voci where !viste.insert(v.chiave).inserted { doppie.insert(v.chiave) }
            return doppie.sorted()
        }
        func valore(_ chiave: String) -> String? {
            // L'ultima definizione è quella che vince a runtime, come nel caricatore di sistema.
            voci.last { $0.chiave == chiave }?.valore
        }
    }

    private func leggiTutte() throws -> [File] {
        let cartelle = try FileManager.default
            .contentsOfDirectory(at: Self.cartella, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertGreaterThanOrEqual(cartelle.count, 20, "le lingue non spariscono")

        return try cartelle.map { cartella in
            let testo = try String(
                contentsOf: cartella.appendingPathComponent("Localizable.strings"), encoding: .utf8)
            var voci: [(String, String)] = []
            for linea in testo.components(separatedBy: .newlines) {
                let raggio = NSRange(linea.startIndex..., in: linea)
                guard let m = Self.riga.firstMatch(in: linea, range: raggio),
                      let k = Range(m.range(at: 1), in: linea),
                      let v = Range(m.range(at: 2), in: linea) else { continue }
                voci.append((String(linea[k]), String(linea[v])))
            }
            return File(
                lingua: String(cartella.lastPathComponent.dropLast(6)),
                voci: voci.map { (chiave: $0.0, valore: $0.1) })
        }
    }

    // MARK: - Le invarianti

    /// Una chiave presente in una lingua e assente in un'altra è una schermata che ricade
    /// sull'inglese senza dirlo a nessuno.
    func testTutteLeLingueHannoLeStesseChiavi() throws {
        let file = try leggiTutte()
        let base = try XCTUnwrap(file.first { $0.lingua == Self.riferimento })

        for f in file where f.lingua != Self.riferimento {
            let mancanti = base.chiavi.subtracting(f.chiavi).sorted()
            let inPiu = f.chiavi.subtracting(base.chiavi).sorted()
            XCTAssertTrue(mancanti.isEmpty, "\(f.lingua): mancano \(mancanti.count) chiavi \(mancanti.prefix(8))")
            XCTAssertTrue(inPiu.isEmpty, "\(f.lingua): ha \(inPiu.count) chiavi che `en` non ha \(inPiu.prefix(8))")
        }
    }

    /// Una chiave definita due volte non è un errore per il caricatore: vince l'ultima, in
    /// silenzio. È così che `platforms.title` ha avuto due valori diversi in 11 lingue, e che il
    /// portoghese ha mostrato per mesi un `ai.placeholder` troncato a metà frase.
    func testNessunaChiaveEDefinitaDueVolte() throws {
        for f in try leggiTutte() {
            XCTAssertTrue(f.duplicate.isEmpty, "\(f.lingua): chiavi duplicate \(f.duplicate)")
        }
    }

    /// I segnaposto devono combaciare con l'inglese. Uno `%d` in più in una traduzione non è una
    /// sfumatura di stile: `String(format:)` legge un argomento che non esiste.
    func testISegnapostoCombacianoConLInglese() throws {
        let file = try leggiTutte()
        let base = try XCTUnwrap(file.first { $0.lingua == Self.riferimento })
        let segnaposto = try NSRegularExpression(pattern: #"%(?:\d+\$)?[@difsu]|%%"#)

        func elenco(_ s: String) -> [String] {
            segnaposto.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .compactMap { Range($0.range, in: s).map { String(s[$0]) } }
                .sorted()
        }

        for f in file where f.lingua != Self.riferimento {
            for (chiave, valore) in f.voci {
                guard let atteso = base.valore(chiave) else { continue }
                XCTAssertEqual(elenco(valore), elenco(atteso),
                               "\(f.lingua)/\(chiave): segnaposto diversi dall'inglese")
            }
        }
    }

    /// Nessun valore vuoto: una stringa vuota non ricade sull'inglese, disegna il nulla.
    func testNessunaTraduzioneEVuota() throws {
        for f in try leggiTutte() {
            let vuote = f.voci.filter { $0.valore.trimmingCharacters(in: .whitespaces).isEmpty }
            XCTAssertTrue(vuote.isEmpty, "\(f.lingua): valori vuoti \(vuote.map(\.chiave))")
        }
    }

    /// Ogni `"chiave".localized` del codice deve esistere in `en`. Senza, `.localized`
    /// restituisce la chiave e l'utente legge `auth.error.invalidLink` sullo schermo.
    func testOgniChiaveUsataNelCodiceEsiste() throws {
        let base = try XCTUnwrap(try leggiTutte().first { $0.lingua == Self.riferimento })
        let radice = Self.cartella.deletingLastPathComponent().deletingLastPathComponent()

        let uso = try NSRegularExpression(
            pattern: #""([a-zA-Z][a-zA-Z0-9_.]*\.[a-zA-Z0-9_.]+)"\s*\.localized"#)
        var usate = Set<String>()

        let enumeratore = FileManager.default.enumerator(at: radice, includingPropertiesForKeys: nil)
        while let url = enumeratore?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  // I doppi di prova hanno chiavi inventate apposta.
                  !url.path.contains("/Tests/"),
                  let testo = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for m in uso.matches(in: testo, range: NSRange(testo.startIndex..., in: testo)) {
                if let r = Range(m.range(at: 1), in: testo) { usate.insert(String(testo[r])) }
            }
        }

        XCTAssertGreaterThan(usate.count, 300, "il grep deve aver trovato davvero le chiavi")
        let orfane = usate.subtracting(base.chiavi).sorted()
        XCTAssertTrue(orfane.isEmpty, "chiavi usate nel codice e assenti da en.lproj: \(orfane)")
    }
}
