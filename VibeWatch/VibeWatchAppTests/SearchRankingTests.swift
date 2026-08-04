import XCTest
@testable import VibeWatchApp

/// L'ordine dei risultati: cercando "Spid" l'utente vedeva film sconosciuti prima di Spider-Man,
/// perché l'app mostrava l'ordine grezzo di TMDB. Questi test fissano la regola: **prima il
/// titolo, poi la popolarità**, e mai il contrario.
final class SearchRankingTests: XCTestCase {

    private func result(
        id: Int, title: String, popularity: Double = 0, votes: Int = 0
    ) -> SearchResult {
        SearchResult(
            id: id, mediaType: "movie", title: title, name: nil, overview: nil,
            posterPath: nil, backdropPath: nil, releaseDate: nil, firstAirDate: nil,
            voteAverage: nil, voteCount: votes, popularity: popularity
        )
    }

    // MARK: - Livelli del punteggio testuale

    func testEsattoBattePrefisso() {
        let esatto = result(id: 1, title: "Alien")
        let prefisso = result(id: 2, title: "Alien Covenant")
        XCTAssertGreaterThan(
            SearchRanking.score(result: esatto, query: "alien"),
            SearchRanking.score(result: prefisso, query: "alien")
        )
    }

    func testPrefissoBattePrefissoDiParola() {
        let prefisso = result(id: 1, title: "Spider-Man")
        let parola = result(id: 2, title: "The Amazing Spider Story")
        XCTAssertGreaterThan(
            SearchRanking.score(result: prefisso, query: "spider"),
            SearchRanking.score(result: parola, query: "spider")
        )
    }

    func testPrefissoDiParolaBatteContiene() {
        let parola = result(id: 1, title: "The Spider Web")
        let contiene = result(id: 2, title: "Arachnospider")
        XCTAssertGreaterThan(
            SearchRanking.score(result: parola, query: "spider"),
            SearchRanking.score(result: contiene, query: "spider")
        )
    }

    func testUnTitoloCheNonContieneLaQueryValeQuasiZero() {
        let fuori = result(id: 1, title: "Qualcos'altro", popularity: 900, votes: 90_000)
        let dentro = result(id: 2, title: "Spider-Man")
        XCTAssertGreaterThan(
            SearchRanking.score(result: dentro, query: "spider"),
            SearchRanking.score(result: fuori, query: "spider")
        )
    }

    /// Il cuore della faccenda: la popolarità non deve poter scavalcare un match migliore.
    ///
    /// "spid" dentro "arachnospidone" è un semplice `contains` — non l'inizio di una parola —
    /// ed è il livello più basso del punteggio testuale: nemmeno con centomila voti risale.
    func testUnMatchEsattoPocoVotatoBatteUnContienePopolarissimo() {
        let esatto = result(id: 1, title: "Spid", popularity: 0.2, votes: 3)
        let contiene = result(id: 2, title: "Il caso Arachnospidone", popularity: 5000, votes: 200_000)

        let ordinati = SearchRanking.rank([contiene, esatto], query: "Spid")
        XCTAssertEqual(ordinati.first?.id, 1)
    }

    /// Il caso vero dell'utente: cercando "Spid", Spider-Man sta sopra un film sconosciuto che
    /// contiene la stessa stringa.
    func testSpiderManBatteUnOmonimoSconosciuto() {
        let spiderMan = result(id: 1, title: "Spider-Man", popularity: 300, votes: 25_000)
        let sconosciuto = result(id: 2, title: "Arachnospidone", popularity: 0.6, votes: 4)

        XCTAssertEqual(SearchRanking.rank([sconosciuto, spiderMan], query: "Spid").map(\.id), [1, 2])
    }

    // MARK: - Pareggi e determinismo

    func testAParitaDiTestoVinceLaPopolarita() {
        let poco = result(id: 1, title: "Spider-Man", popularity: 1)
        let molto = result(id: 2, title: "Spider-Man", popularity: 500)

        let ordinati = SearchRanking.rank([poco, molto], query: "spider-man")
        XCTAssertEqual(ordinati.map(\.id), [2, 1])
    }

    func testAParitaPienaLOrdineEDeterministico() {
        let a = result(id: 7, title: "Uguale")
        let b = result(id: 3, title: "Uguale")

        XCTAssertEqual(SearchRanking.rank([a, b], query: "uguale").map(\.id), [3, 7])
        XCTAssertEqual(SearchRanking.rank([b, a], query: "uguale").map(\.id), [3, 7])
    }

    // MARK: - Normalizzazione

    func testGliAccentiNonContano() {
        let accentato = result(id: 1, title: "Pokémon")
        XCTAssertEqual(SearchRanking.score(result: accentato, query: "pokemon"),
                       SearchRanking.score(result: accentato, query: "Pokémon"))
        XCTAssertGreaterThan(SearchRanking.score(result: accentato, query: "pokemon"), 0.5)
    }

    func testGliSpaziAiBordiNonContano() {
        let titolo = result(id: 1, title: "Alien")
        XCTAssertEqual(SearchRanking.score(result: titolo, query: "  alien  "),
                       SearchRanking.score(result: titolo, query: "alien"))
    }

    func testUnaQueryVuotaNonOrdinaNiente() {
        let titolo = result(id: 1, title: "Alien")
        XCTAssertEqual(SearchRanking.score(result: titolo, query: "   "), 0)
    }

    func testNormalizeToglieAccentiEMaiuscole() {
        XCTAssertEqual(SearchRanking.normalize("  Pokémon GO "), "pokemon go")
    }

    // MARK: - rank

    func testRankNonPerdeNePuplicaRisultati() {
        let items = (1...10).map { result(id: $0, title: "Titolo \($0)") }
        let ordinati = SearchRanking.rank(items, query: "titolo")
        XCTAssertEqual(Set(ordinati.map(\.id)), Set(items.map(\.id)))
        XCTAssertEqual(ordinati.count, items.count)
    }

    // MARK: - Evidenziazione nel titolo

    /// Il tratto corrispondente si colora, il resto no: gli indici della stringa normalizzata
    /// devono ricadere sui caratteri giusti del titolo originale.
    func testLaQueryEvidenziaIlPrefissoDelTitolo() {
        let evidenziato = SearchRankedRow.highlighted("Spider-Man: Brand New Day", query: "sp")
        let colorati = evidenziato.runs.filter { $0.foregroundColor != nil }

        XCTAssertEqual(colorati.count, 1)
        XCTAssertEqual(colorati.first.map { String(evidenziato[$0.range].characters) }, "Sp")
    }

    /// Il match può stare a metà titolo, non solo in testa.
    func testLaQueryEvidenziaAncheDentroIlTitolo() {
        let evidenziato = SearchRankedRow.highlighted("The Amazing Spider-Man", query: "spider")
        let colorati = evidenziato.runs.filter { $0.foregroundColor != nil }

        XCTAssertEqual(colorati.first.map { String(evidenziato[$0.range].characters) }, "Spider")
    }

    /// Accenti: la ricerca li ignora, l'evidenziazione deve restare sul carattere accentato.
    func testLEvidenziazioneReggeGliAccenti() {
        let evidenziato = SearchRankedRow.highlighted("Pokémon", query: "poke")
        let colorati = evidenziato.runs.filter { $0.foregroundColor != nil }

        XCTAssertEqual(colorati.first.map { String(evidenziato[$0.range].characters) }, "Poké")
    }

    func testSenzaCorrispondenzaNienteColore() {
        let evidenziato = SearchRankedRow.highlighted("Alien", query: "zz")
        XCTAssertTrue(evidenziato.runs.allSatisfy { $0.foregroundColor == nil })
    }
}
