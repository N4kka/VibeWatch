import XCTest
@testable import VibeWatchApp

/// Il conteggio del wrap-up (mese/anno) sulle DUE sorgenti dei film.
///
/// **Perché esiste questo test.** `watch_events` da solo risponde "0 film" a quasi tutti: nell'app
/// i film segnati visti finiscono solo in `list_items` della lista `seen`, e l'unico writer di
/// eventi per i film è l'import TV Time. È la stessa asimmetria che `20260803150000` ha risolto
/// server-side per `get_my_stats`; qui la regola è ricostruita sul client, e senza una verifica
/// una card di zeri passerebbe la revisione e il build senza far rumore — la si scoprirebbe solo
/// pubblicandola.
@MainActor
final class WrapUpBuilderTests: XCTestCase {

    // Agosto 2026 nel calendario locale, come lo calcola WrapUpPeriod.
    private let period = WrapUpPeriod.month(year: 2026, month: 8)
    private var range: (start: Date, end: Date) { period.range()! }

    private func iso(_ value: String) -> String { value }

    /// Una riga di `watch_events` come la restituisce SQLite.
    private func event(mediaType: String, showId: Int? = nil, movieId: Int? = nil,
                       runtimeSeconds: Int? = nil, watchedAt: String,
                       showName: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["media_type": mediaType, "watched_at": watchedAt]
        if let showId { row["tmdb_show_id"] = showId }
        if let movieId { row["tmdb_movie_id"] = movieId }
        if let runtimeSeconds { row["runtime_seconds"] = runtimeSeconds }
        if let showName { row["show_name"] = showName }
        return row
    }

    /// Una riga di `list_items` della lista "visti".
    private func seenMovie(id: Int, title: String, runtime: Int?, addedAt: String) -> [String: Any] {
        var row: [String: Any] = ["media_id": id, "title": title, "added_at": addedAt]
        if let runtime { row["runtime"] = runtime }
        return row
    }

    private func aggregate(events: [[String: Any]] = [],
                           seen: [[String: Any]] = [],
                           runtimes: [Int: Int] = [:],
                           moviesWithEvents: Set<Int> = []) -> WrapUpSummary {
        WrapUpBuilder.aggregate(
            eventRows: events, seenMovieRows: seen,
            movieRuntimeMinutes: runtimes, moviesWithEvents: moviesWithEvents,
            period: period, range: range)
    }

    // MARK: - I film della lista "visti"

    func testUnUtenteDiSoliFilmNonRiceveUnaCardDiZeri() {
        // Nessun watch_event: è la condizione normale di chi segna i film dall'app.
        let summary = aggregate(seen: [
            seenMovie(id: 603, title: "The Matrix", runtime: 136,
                      addedAt: iso("2026-08-03T21:00:00Z")),
            seenMovie(id: 157336, title: "Interstellar", runtime: 169,
                      addedAt: iso("2026-08-11T22:00:00Z")),
        ])

        XCTAssertEqual(summary.movies, 2, "i film della lista visti contano")
        XCTAssertEqual(summary.episodes, 0)
        XCTAssertFalse(summary.isEmpty, "e la card ha qualcosa da dire")
        XCTAssertEqual(summary.hours, (136 + 169) / 60, "coi minuti di catalogo della riga di lista")
        XCTAssertEqual(summary.activeDays, 2)
        XCTAssertEqual(Set(summary.topTitles.map(\.title)), ["The Matrix", "Interstellar"],
                       "titolo e poster ce li ha già la riga di lista: niente giro da TMDB")
    }

    func testUnFilmConEventoNonSiContaDueVolte() {
        // Stesso film in entrambe le sorgenti: vince l'evento, che porta la sua data.
        let summary = aggregate(
            events: [event(mediaType: "movie", movieId: 603, runtimeSeconds: 8160,
                           watchedAt: iso("2026-08-03T21:00:00Z"))],
            seen: [seenMovie(id: 603, title: "The Matrix", runtime: 136,
                             addedAt: iso("2026-08-04T09:00:00Z"))],
            moviesWithEvents: [603])

        XCTAssertEqual(summary.movies, 1, "una sola volta")
        XCTAssertEqual(summary.hours, 8160 / 3600)
        XCTAssertEqual(summary.activeDays, 1, "e il giorno è quello dell'evento, non dell'aggiunta")
    }

    func testFuoriDalPeriodoNonEntraNiente() {
        // Il prefiltro SQL è largo un giorno per lato apposta (i timestamp sono UTC, il periodo
        // è nel calendario locale): il taglio esatto lo fa l'aggregazione, ed è questo.
        let summary = aggregate(
            events: [event(mediaType: "tv", showId: 1396, runtimeSeconds: 2820,
                           watchedAt: iso("2026-07-30T12:00:00Z"), showName: "Breaking Bad")],
            seen: [seenMovie(id: 603, title: "The Matrix", runtime: 136,
                             addedAt: iso("2026-09-02T10:00:00Z"))])

        XCTAssertTrue(summary.isEmpty)
    }

    func testIlConfineDelPeriodoSegueIlCalendarioLocale() {
        // Un istante UTC che nel fuso locale cade DENTRO il mese deve contare: il periodo è
        // quello che l'utente legge sul calendario, non quello del meridiano di Greenwich.
        let localStart = range.start
        let summary = aggregate(events: [
            event(mediaType: "tv", showId: 1396, runtimeSeconds: 2820,
                  watchedAt: ISO8601DateFormatter().string(from: localStart.addingTimeInterval(60)),
                  showName: "Breaking Bad"),
            event(mediaType: "tv", showId: 1396, runtimeSeconds: 2820,
                  watchedAt: ISO8601DateFormatter().string(from: localStart.addingTimeInterval(-60)),
                  showName: "Breaking Bad"),
        ])

        XCTAssertEqual(summary.episodes, 1, "dentro l'estremo iniziale sì, un minuto prima no")
    }

    // MARK: - Le ore

    func testIMinutiDiCatalogoColmanoGliEventiFilmSenzaDurata() {
        // Gli eventi film dell'import arrivano quasi sempre senza runtime_seconds: senza il
        // ripiego, un mese di soli film importati direbbe "0 ore".
        let senzaRipiego = aggregate(
            events: [event(mediaType: "movie", movieId: 603,
                           watchedAt: iso("2026-08-03T21:00:00Z"))])
        XCTAssertNil(senzaRipiego.hours, "senza durata nota le ore non si inventano")

        let conRipiego = aggregate(
            events: [event(mediaType: "movie", movieId: 603,
                           watchedAt: iso("2026-08-03T21:00:00Z"))],
            runtimes: [603: 136])
        XCTAssertEqual(conRipiego.hours, (136 * 60) / 3600)
        XCTAssertEqual(conRipiego.movies, 1, "il film conta comunque, con o senza durata")
    }

    func testLeOreSommanoSerieEFilmInsieme() {
        let summary = aggregate(
            events: [
                event(mediaType: "tv", showId: 1396, runtimeSeconds: 2820,
                      watchedAt: iso("2026-08-05T20:00:00Z"), showName: "Breaking Bad"),
                event(mediaType: "tv", showId: 1396, runtimeSeconds: 2820,
                      watchedAt: iso("2026-08-05T21:00:00Z"), showName: "Breaking Bad"),
            ],
            seen: [seenMovie(id: 157336, title: "Interstellar", runtime: 169,
                             addedAt: iso("2026-08-06T22:00:00Z"))])

        XCTAssertEqual(summary.episodes, 2)
        XCTAssertEqual(summary.movies, 1)
        XCTAssertEqual(summary.hours, (2820 * 2 + 169 * 60) / 3600,
                       "un'unica somma: episodi e film nello stesso monte ore")
        XCTAssertEqual(summary.activeDays, 2, "due giorni distinti, non tre eventi")
    }

    // MARK: - I titoli in evidenza

    func testLaSerieAccumulaEpisodiSuUnaCardSola() {
        let summary = aggregate(events: (1...3).map { hour in
            event(mediaType: "tv", showId: 1396, runtimeSeconds: 2820,
                  watchedAt: iso("2026-08-05T2\(hour):00:00Z"), showName: "Breaking Bad")
        })

        XCTAssertEqual(summary.topTitles.count, 1)
        XCTAssertEqual(summary.topTitles.first?.episodes, 3)
        XCTAssertEqual(summary.episodes, 3)
    }

    func testLaGrigliaSiFermaAQuattroTitoli() {
        let summary = aggregate(seen: (1...6).map { index in
            seenMovie(id: 100 + index, title: "Film \(index)", runtime: 100,
                      addedAt: iso("2026-08-0\(index)T20:00:00Z"))
        })

        XCTAssertEqual(summary.movies, 6, "contati tutti")
        XCTAssertEqual(summary.topTitles.count, 4, "ma in griglia ne stanno quattro")
    }
}
