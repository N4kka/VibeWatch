import XCTest
@testable import VibeWatchApp

/// Le righe "Informazioni" e i loro formattatori: tutta logica pura, tutta verificabile.
///
/// La regola che questi test difendono è una sola: **una riga esiste solo se il dato c'è**.
/// TMDB scrive `0` dove non sa, e uno "0 $" di budget è peggio di nessuna riga.
final class MediaInfoFormattingTests: XCTestCase {

    // MARK: - Valuta

    func testLaValutaSiAbbreviaAiMilioni() {
        XCTAssertEqual(MediaInfoFormatting.formatCurrencyCompact(185_000_000), "$185M")
        XCTAssertEqual(MediaInfoFormatting.formatCurrencyCompact(8_500_000), "$8.5M")
    }

    func testLaValutaSiAbbreviaAiMiliardi() {
        XCTAssertEqual(MediaInfoFormatting.formatCurrencyCompact(2_800_000_000), "$2.8B")
    }

    func testLeMigliaia() {
        XCTAssertEqual(MediaInfoFormatting.formatCurrencyCompact(45_000), "$45K")
    }

    func testGliImportiPiccoliRestanoInteri() {
        XCTAssertEqual(MediaInfoFormatting.formatCurrencyCompact(750), "$750")
    }

    func testZeroENilValgonoDatoAssente() {
        XCTAssertNil(MediaInfoFormatting.formatCurrencyCompact(0))
        XCTAssertNil(MediaInfoFormatting.formatCurrencyCompact(nil))
        XCTAssertNil(MediaInfoFormatting.formatCurrencyCompact(-1))
    }

    // MARK: - Date

    func testUnaDataTMDBDiventaUnaDataLeggibile() {
        XCTAssertNotNil(MediaInfoFormatting.formatDate("1994-10-14"))
    }

    func testUnaDataMalformataNonProduceRiga() {
        XCTAssertNil(MediaInfoFormatting.formatDate("1994"))
        XCTAssertNil(MediaInfoFormatting.formatDate(""))
        XCTAssertNil(MediaInfoFormatting.formatDate(nil))
    }

    // MARK: - Stato

    func testGliStatiNotiSonoLocalizzati() {
        XCTAssertEqual(MediaInfoFormatting.localizedStatus("Released"), "mediaStatus.released".localized)
        XCTAssertEqual(MediaInfoFormatting.localizedStatus("Returning Series"),
                       "mediaStatus.returningSeries".localized)
        // La grafia britannica arriva davvero da TMDB.
        XCTAssertEqual(MediaInfoFormatting.localizedStatus("Cancelled"),
                       "mediaStatus.canceled".localized)
    }

    func testUnoStatoSconosciutoRestaComEra() {
        XCTAssertEqual(MediaInfoFormatting.localizedStatus("Something New"), "Something New")
        XCTAssertNil(MediaInfoFormatting.localizedStatus(nil))
    }

    // MARK: - Righe del film

    private func movie(
        budget: Int? = nil,
        revenue: Int? = nil,
        companies: [ProductionCompany]? = nil,
        tagline: String? = nil,
        status: String? = nil
    ) -> Movie {
        Movie(
            id: 1, title: "Pulp Fiction", overview: "", posterPath: nil, backdropPath: nil,
            releaseDate: "1994-10-14", voteAverage: 8.9, voteCount: 2099, genreIds: nil,
            genres: [Genre(id: 18, name: "Drama")], adult: false, originalLanguage: "en",
            popularity: 50, runtime: 154, status: status, tagline: tagline,
            productionCountries: nil, imdbId: nil, budget: budget, revenue: revenue,
            productionCompanies: companies, spokenLanguages: nil
        )
    }

    func testSenzaBudgetNonCEUnaRigaBudget() {
        let rows = MovieCreditsInfoBuilder.rows(movie: movie(), director: nil)
        XCTAssertFalse(rows.contains { $0.titleKey == "movieDetail.budget" })
        XCTAssertFalse(rows.contains { $0.titleKey == "movieDetail.revenue" })
    }

    func testConBudgetEIncassiLeRigheCiSono() {
        let rows = MovieCreditsInfoBuilder.rows(
            movie: movie(budget: 8_000_000, revenue: 213_900_000), director: nil)
        XCTAssertEqual(rows.first { $0.titleKey == "movieDetail.budget" }?.value, "$8M")
        XCTAssertEqual(rows.first { $0.titleKey == "movieDetail.revenue" }?.value, "$213.9M")
    }

    func testLeCaseDiProduzioneSiUnisconoConLaVirgola() {
        let rows = MovieCreditsInfoBuilder.rows(
            movie: movie(companies: [
                ProductionCompany(id: 1, name: "Miramax", logoPath: nil),
                ProductionCompany(id: 2, name: "A Band Apart", logoPath: nil)
            ]),
            director: nil)
        XCTAssertEqual(rows.first { $0.titleKey == "movieDetail.productionCompanies" }?.value,
                       "Miramax, A Band Apart")
    }

    func testLaTaglineEInCorsivoEStaInFondo() {
        let rows = MovieCreditsInfoBuilder.rows(movie: movie(tagline: "Just because you are…"),
                                                director: nil)
        XCTAssertEqual(rows.last?.titleKey, "movieDetail.tagline")
        XCTAssertEqual(rows.last?.isItalic, true)
    }

    func testUnaTaglineDiSoliSpaziNonFaRiga() {
        let rows = MovieCreditsInfoBuilder.rows(movie: movie(tagline: "   "), director: nil)
        XCTAssertFalse(rows.contains { $0.titleKey == "movieDetail.tagline" })
    }

    func testLoStatoDelFilmDiventaUnaRiga() {
        let rows = MovieCreditsInfoBuilder.rows(movie: movie(status: "Released"), director: nil)
        XCTAssertEqual(rows.first { $0.titleKey == "movieDetail.status" }?.value,
                       "mediaStatus.released".localized)
    }

    // MARK: - Righe della serie

    private func show(
        seasons: Int? = nil,
        episodes: Int? = nil,
        networks: [ProductionCompany]? = nil,
        creators: [Creator]? = nil,
        status: String? = nil
    ) -> TVShow {
        TVShow(
            id: 2, name: "Bleach", overview: "", posterPath: nil, backdropPath: nil,
            firstAirDate: "2004-10-05", voteAverage: 8.4, voteCount: 900, genreIds: nil,
            genres: nil, originalLanguage: "ja", popularity: 90, status: status, tagline: nil,
            productionCountries: nil, imdbId: nil, numberOfSeasons: seasons,
            episodeRunTime: [24], lastAirDate: "2012-03-27", numberOfEpisodes: episodes,
            inProduction: false, seasons: nil, nextEpisodeToAir: nil, networks: networks,
            createdBy: creators, type: "Scripted", lastEpisodeToAir: nil
        )
    }

    func testStagioniEdEpisodiStannoSullaStessaRiga() {
        let rows = TVShowCreditsInfoBuilder.rows(tvShow: show(seasons: 9, episodes: 191), director: nil)
        let value = rows.first { $0.titleKey == "tvDetail.seasonsEpisodes" }?.value
        XCTAssertEqual(value, "\(String(format: "tvDetail.seasonsCount".localized, 9)) · "
                       + "\(String(format: "tvDetail.episodesCount".localized, 191))")
    }

    func testSenzaStagioniNonCELaRiga() {
        let rows = TVShowCreditsInfoBuilder.rows(tvShow: show(), director: nil)
        XCTAssertFalse(rows.contains { $0.titleKey == "tvDetail.seasonsEpisodes" })
    }

    func testICreatoriHannoLaPrecedenzaSulRegista() {
        let regista = Crew(id: 9, name: "Regista", job: "Director", department: "Directing", profilePath: nil)
        let rows = TVShowCreditsInfoBuilder.rows(
            tvShow: show(creators: [Creator(id: 3, name: "Tite Kubo")]), director: regista)
        XCTAssertEqual(rows.first { $0.titleKey == "tvDetail.createdBy" }?.value, "Tite Kubo")
        XCTAssertFalse(rows.contains { $0.titleKey == "movieDetail.director" })
    }

    func testSenzaCreatoriRestaIlRegista() {
        let regista = Crew(id: 9, name: "Regista", job: "Director", department: "Directing", profilePath: nil)
        let rows = TVShowCreditsInfoBuilder.rows(tvShow: show(), director: regista)
        XCTAssertEqual(rows.first { $0.titleKey == "movieDetail.director" }?.value, "Regista")
    }

    func testIlNetworkDiventaUnaRiga() {
        let rows = TVShowCreditsInfoBuilder.rows(
            tvShow: show(networks: [ProductionCompany(id: 4, name: "TV Tokyo", logoPath: nil)]),
            director: nil)
        XCTAssertEqual(rows.first { $0.titleKey == "tvDetail.network" }?.value, "TV Tokyo")
    }

    /// `ForEach(..., id: \.titleKey)` disegna le righe: una chiave ripetuta ne farebbe sparire una.
    func testLeChiaviDelleRigheSonoUniche() {
        let movieRows = MovieCreditsInfoBuilder.rows(
            movie: movie(budget: 1_000_000, revenue: 2_000_000, tagline: "x", status: "Released"),
            director: Crew(id: 1, name: "QT", job: "Director", department: "Directing", profilePath: nil))
        XCTAssertEqual(Set(movieRows.map(\.titleKey)).count, movieRows.count)

        let showRows = TVShowCreditsInfoBuilder.rows(
            tvShow: show(seasons: 9, episodes: 191,
                         networks: [ProductionCompany(id: 4, name: "TV Tokyo", logoPath: nil)],
                         creators: [Creator(id: 3, name: "Tite Kubo")], status: "Ended"),
            director: nil)
        XCTAssertEqual(Set(showRows.map(\.titleKey)).count, showRows.count)
    }
}
