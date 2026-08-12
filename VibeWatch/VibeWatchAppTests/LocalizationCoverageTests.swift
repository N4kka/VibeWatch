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

    /// Nessun file è la copia di un altro.
    ///
    /// `nl.lproj` è stato per mesi una copia di `pl.lproj` — differivano per 14 stringhe su 571 —
    /// e ogni utente olandese leggeva polacco. Nessun controllo se ne accorgeva: il file esisteva,
    /// aveva tutte le chiavi giuste e passava ogni verifica di completezza. La sola cosa che lo
    /// distingueva da una traduzione vera era il **contenuto**, e questo test guarda quello.
    ///
    /// La soglia sta all'85% perché due file di lingue diverse condividono solo prestiti e
    /// simboli: la coppia più simile dopo `nb`/`no` sta al 24%, mentre `nl`/`pl` stava al 97%.
    func testNessunaLinguaEUnaCopiaDiUnAltra() throws {
        let file = try leggiTutte()
        // Bokmål e "norvegese" sono la stessa lingua con due codici, e i due file si somigliano
        // per costruzione: è l'unica coppia legittima, e sta scritta qui invece che nella soglia.
        let coppieAmmesse: Set<Set<String>> = [["nb", "no"]]

        // Un dizionario per file, costruito una volta: `valore(_:)` scandisce le voci in ordine,
        // e 190 coppie × 597 chiavi di scansioni lineari facevano di questo test il più lento
        // della suite per nessuna ragione.
        let mappe: [(lingua: String, valori: [String: String])] = file.map { f in
            var m: [String: String] = [:]
            for v in f.voci { m[v.chiave] = v.valore }   // l'ultima vince, come a runtime
            return (f.lingua, m)
        }

        for i in mappe.indices {
            for j in (i + 1)..<mappe.count {
                let (a, b) = (mappe[i], mappe[j])
                if coppieAmmesse.contains([a.lingua, b.lingua]) { continue }

                let comuni = Set(a.valori.keys).intersection(b.valori.keys)
                guard !comuni.isEmpty else { continue }
                let uguali = comuni.filter { a.valori[$0] == b.valori[$0] }.count
                let quota = Double(uguali) / Double(comuni.count)

                XCTAssertLessThan(quota, 0.85, String(
                    format: "%@ e %@ sono identici al %.0f%%: uno dei due non è tradotto",
                    a.lingua, b.lingua, quota * 100))
            }
        }
    }

    /// I prestiti inglesi ammessi in **tutte** le lingue.
    ///
    /// Sono nomi propri (`VibeWatch`, `JustWatch`, `TV Time`), sigle entrate nell'uso ovunque
    /// (`AI`, `OK`, `PRO`, `FAQ`) e formati puramente numerici (`8.0+`, `< 90 min`, `{count}/{limit}`).
    /// Tutto il resto, se in una lingua è identico all'inglese, è una stringa non tradotta.
    private static let prestitiAmmessi: Set<String> = [
        "tab.ai", "ai.title", "common.ok", "common.pro", "common.privacy",
        "discovery.vibeWatch", "import.banner.ok", "import.source.tvtime",
        "platforms.justwatch", "profile.faq", "settings.privacy.title",
        "lists.limitInfo", "import.report.sourcePeriod",
        "filters.ratingGood", "filters.ratingExcellent", "filters.ratingMasterpiece",
        "filters.runtimeShort", "filters.runtimeMedium", "filters.runtimeLong",
        "auth.emailPlaceholder", "tracking.title", "tab.tracking",
        "gamification.levelShort",
    ]

    /// I prestiti decisi lingua per lingua.
    ///
    /// "Watchlist" è italiano corrente e cinese no; "Cast" e "Trailer" sono entrati in molte
    /// lingue europee e in nessuna asiatica. Ogni voce qui è una scelta, non una dimenticanza:
    /// se una riga sparisce da questa mappa il test la segnala, ed è esattamente quello che serve.
    private static let prestitiPerLingua: [String: Set<String>] = [
        // da: 27
        "da": [
            "auth.pwRule.symbol",
            "clips.card.addToWatchlist",
            "filters.min",
            "filters.myPlatforms",
            "gamification.badges.title",
            "genre.action",
            "genre.animation",
            "genre.drama",
            "genre.fantasy",
            "genre.reality",
            "genre.soap",
            "genre.thriller",
            "genre.western",
            "lists.watchlist",
            "mediaDetail.action.like",
            "mediaDetail.action.watchlist",
            "mediaStatus.pilot",
            "movieDetail.budget",
            "movieDetail.information",
            "movieDetail.status",
            "movieDetail.trailer",
            "notifications.status",
            "platforms.streaming",
            "profile.feedback.category.ui",
            "profile.feedback.sendButton",
            "tracking.special",
            "update.versionFootnote",
        ],
        // de: 29
        "de": [
            "carousel.topInGenre",
            "clips.card.addToWatchlist",
            "clips.title",
            "gamification.level",
            "gamification.levelNumber",
            "genre.action",
            "genre.animation",
            "genre.drama",
            "genre.fantasy",
            "genre.horror",
            "genre.mystery",
            "genre.sciFiFantasy",
            "genre.thriller",
            "genre.western",
            "import.report.details",
            "lists.watchlist",
            "mediaDetail.action.like",
            "mediaDetail.action.watchlist",
            "movieDetail.budget",
            "movieDetail.genres",
            "movieDetail.status",
            "movieDetail.trailer",
            "notifications.status",
            "platforms.streaming",
            "profile.edit.bio",
            "profile.edit.name",
            "tab.clips",
            "tracking.special",
            "update.versionFootnote",
        ],
        // es: 14
        "es": [
            "clips.title",
            "common.error",
            "gamification.xp.base",
            "genre.drama",
            "genre.romance",
            "genre.western",
            "mood.nostalgic",
            "mood.romantic",
            "movieDetail.director",
            "platforms.streaming",
            "profile.legal",
            "search.scope.series",
            "tab.clips",
            "tab.social",
        ],
        // fi: 3
        "fi": [
            "filters.min",
            "genre.western",
            "mood.nostalgic",
        ],
        // fr: 28
        "fr": [
            "clips.card.addToWatchlist",
            "clips.title",
            "filters.max",
            "filters.min",
            "gamification.badges.title",
            "gamification.xp.base",
            "genre.action",
            "genre.animation",
            "genre.crime",
            "genre.romance",
            "genre.thriller",
            "genre.western",
            "lists.collections",
            "mediaDetail.action.watchlist",
            "mediaStatus.postProduction",
            "mood.romantic",
            "movieDetail.budget",
            "movieDetail.genres",
            "movieDetail.productionCompanies",
            "notifications.title",
            "platforms.streaming",
            "profile.edit.bio",
            "profile.feedback.category.notifications",
            "profile.notifications",
            "settings.notifications.title",
            "tab.clips",
            "tab.social",
            "update.versionFootnote",
        ],
        // it: 25
        "it": [
            "auth.passwordPlaceholder",
            "clips.card.addToWatchlist",
            "favorites.slot",
            "filters.min",
            "gamification.xp.base",
            "genre.crime",
            "genre.fantasy",
            "genre.horror",
            "genre.reality",
            "genre.thriller",
            "genre.western",
            "mediaDetail.action.watchlist",
            "mood.nostalgic",
            "movieDetail.budget",
            "movieDetail.cast",
            "movieDetail.trailer",
            "onboarding.import.stat.watchlist",
            "platforms.cinema",
            "platforms.streaming",
            "profile.edit.bio",
            "profile.feedback.category.crash",
            "profile.group.account",
            "profile.passwordPlaceholder",
            "tab.social",
            "username.placeholder",
        ],
        // nb: 16
        "nb": [
            "auth.pwRule.symbol",
            "clips.card.addToWatchlist",
            "filters.min",
            "filters.myPlatforms",
            "genre.action",
            "genre.drama",
            "genre.fantasy",
            "genre.reality",
            "genre.scienceFiction",
            "genre.thriller",
            "genre.western",
            "lists.watchlist",
            "mediaDetail.action.watchlist",
            "movieDetail.status",
            "movieDetail.trailer",
            "notifications.status",
        ],
        // nl: 40
        "nl": [
            "clips.card.addToWatchlist",
            "clips.search.quotes",
            "clips.title",
            "common.item",
            "common.items",
            "discovery.releases.countMany",
            "discovery.releases.countOne",
            "discovery.releases.title",
            "filters.max",
            "filters.min",
            "filters.releasePeriodModern",
            "filters.releasePeriodRecent",
            "filters.title",
            "gamification.badges.title",
            "gamification.challenge.like_5",
            "genre.drama",
            "genre.fantasy",
            "genre.horror",
            "genre.sciFiFantasy",
            "genre.soap",
            "genre.thriller",
            "genre.western",
            "import.report.details",
            "lists.watchlist",
            "mediaDetail.action.like",
            "mediaDetail.action.watchlist",
            "mediaStatus.pilot",
            "movieDetail.budget",
            "movieDetail.cast",
            "movieDetail.genres",
            "movieDetail.status",
            "movieDetail.trailer",
            "notifications.status",
            "profile.edit.bio",
            "profile.feedback.category.crash",
            "profile.group.account",
            "search.scope.series",
            "tab.clips",
            "tracking.action.later",
            "tracking.special",
        ],
        // no: 16
        "no": [
            "auth.pwRule.symbol",
            "clips.card.addToWatchlist",
            "filters.min",
            "filters.myPlatforms",
            "genre.action",
            "genre.drama",
            "genre.fantasy",
            "genre.reality",
            "genre.scienceFiction",
            "genre.thriller",
            "genre.western",
            "lists.watchlist",
            "mediaDetail.action.watchlist",
            "movieDetail.status",
            "movieDetail.trailer",
            "notifications.status",
        ],
        // pl: 11
        "pl": [
            "auth.pwRule.symbol",
            "filters.min",
            "genre.fantasy",
            "genre.horror",
            "genre.thriller",
            "genre.western",
            "import.title",
            "mood.nostalgic",
            "movieDetail.status",
            "notifications.status",
            "platforms.streaming",
        ],
        // pt: 13
        "pt": [
            "clips.title",
            "common.item",
            "gamification.xp.base",
            "genre.crime",
            "genre.drama",
            "genre.romance",
            "mood.nostalgic",
            "mood.romantic",
            "movieDetail.trailer",
            "platforms.cinema",
            "platforms.streaming",
            "tab.clips",
            "tab.social",
        ],
        // sv: 19
        "sv": [
            "auth.pwRule.symbol",
            "filters.max",
            "filters.min",
            "genre.action",
            "genre.drama",
            "genre.fantasy",
            "genre.reality",
            "genre.scienceFiction",
            "genre.thriller",
            "genre.western",
            "movieDetail.budget",
            "movieDetail.information",
            "movieDetail.status",
            "movieDetail.trailer",
            "notifications.status",
            "platforms.streaming",
            "profile.edit.information",
            "tracking.special",
            "update.versionFootnote",
        ],
        // tr: 3
        "tr": [
            "filters.min",
            "filters.releasePeriodModern",
            "genre.talk",
        ],
    ]

    /// Nessuna stringa inglese in una lingua che non è l'inglese.
    ///
    /// **Perché serve.** Con l'app in italiano la schermata Scopri mostrava "Il meglio di Science
    /// Fiction" e "Scelti dallo staff per fan di Your Favorites": il template era tradotto, la
    /// parola dentro no. Lo stesso vale per una traduzione semplicemente dimenticata, che resta
    /// identica all'inglese e non fa fallire nulla — `testNessunaLinguaEUnaCopiaDiUnAltra` scatta
    /// solo se un file INTERO è una copia, non se lo sono novanta righe su mille.
    ///
    /// Le eccezioni per lingua stanno in `prestitiPerLingua`: un prestito è una decisione
    /// consapevole su una parola precisa ("Watchlist" in italiano sì, in cinese no), e va scritta
    /// qui perché la prossima persona sappia che è voluta.
    func testNessunaLinguaLasciaStringheInInglese() throws {
        let file = try leggiTutte()
        let base = try XCTUnwrap(file.first { $0.lingua == Self.riferimento })

        for f in file where f.lingua != Self.riferimento {
            let ammesse = Self.prestitiAmmessi.union(Self.prestitiPerLingua[f.lingua] ?? [])
            let inglesi = base.chiavi
                .filter { !ammesse.contains($0) }
                .filter { chiave in
                    guard let mia = f.valore(chiave), let en = base.valore(chiave) else { return false }
                    return mia == en
                }
                .sorted()

            XCTAssertTrue(inglesi.isEmpty, """
                \(f.lingua): \(inglesi.count) stringhe identiche all'inglese.
                Se sono traduzioni mancanti, traducile. Se sono prestiti voluti, aggiungile a
                `prestitiPerLingua["\(f.lingua)"]` con il perché.
                \(inglesi.map { "  \($0) = \"\(base.valore($0) ?? "")\"" }.joined(separator: "\n"))
                """)
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
