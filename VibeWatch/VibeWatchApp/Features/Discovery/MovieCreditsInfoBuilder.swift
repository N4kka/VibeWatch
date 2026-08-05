import Foundation

/// Le righe della sezione "Informazioni" di un film: funzione pura, così si verifica senza UI.
///
/// Regola unica: una riga esiste solo se il dato c'è. Un "Budget —" non informa nessuno, e TMDB
/// lascia a zero i campi che non conosce.
enum MovieCreditsInfoBuilder {

    struct Row: Equatable {
        let titleKey: String
        let value: String
        /// La tagline si legge in corsivo, come una citazione.
        var isItalic: Bool = false
    }

    static func rows(movie: Movie, director: Crew?) -> [Row] {
        var rows: [Row] = []

        if movie.ratingPercentage > 0 {
            rows.append(Row(titleKey: "movieDetail.rating", value: "\(movie.ratingPercentage)%"))
        }

        if let genres = movie.genres, !genres.isEmpty {
            rows.append(Row(titleKey: "movieDetail.genres", value: genres.map { $0.name }.joined(separator: ", ")))
        }

        if let runtime = movie.formattedRuntime {
            rows.append(Row(titleKey: "movieDetail.runtime", value: runtime))
        }

        if let released = MediaInfoFormatting.formatDate(movie.releaseDate) {
            rows.append(Row(titleKey: "movieDetail.releaseDate", value: released))
        }

        if let status = MediaInfoFormatting.localizedStatus(movie.status) {
            rows.append(Row(titleKey: "movieDetail.status", value: status))
        }

        if let country = movie.productionCountries?.first,
           let name = MediaInfoFormatting.localizedCountry(iso: country.iso, fallback: country.name) {
            rows.append(Row(titleKey: "movieDetail.country", value: name))
        }

        if let director {
            rows.append(Row(titleKey: "movieDetail.director", value: director.name))
        }

        if let companies = movie.productionCompanies, !companies.isEmpty {
            rows.append(Row(
                titleKey: "movieDetail.productionCompanies",
                value: companies.map(\.name).joined(separator: ", ")
            ))
        }

        if let budget = MediaInfoFormatting.formatCurrencyCompact(movie.budget) {
            rows.append(Row(titleKey: "movieDetail.budget", value: budget))
        }

        if let revenue = MediaInfoFormatting.formatCurrencyCompact(movie.revenue) {
            rows.append(Row(titleKey: "movieDetail.revenue", value: revenue))
        }

        if let language = MediaInfoFormatting.localizedLanguage(movie.originalLanguage) {
            rows.append(Row(titleKey: "movieDetail.originalLanguage", value: language))
        }

        if let tagline = movie.tagline, !tagline.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(Row(titleKey: "movieDetail.tagline", value: tagline, isItalic: true))
        }

        return rows
    }
}

/// L'equivalente per le serie: prima queste righe erano scritte a mano dentro la view, e
/// divergevano da quelle dei film senza che nessun test se ne accorgesse.
enum TVShowCreditsInfoBuilder {

    static func rows(tvShow: TVShow, director: Crew?) -> [MovieCreditsInfoBuilder.Row] {
        typealias Row = MovieCreditsInfoBuilder.Row
        var rows: [Row] = []

        if tvShow.ratingPercentage > 0 {
            rows.append(Row(titleKey: "movieDetail.rating", value: "\(tvShow.ratingPercentage)%"))
        }

        if let genres = tvShow.genres, !genres.isEmpty {
            rows.append(Row(titleKey: "movieDetail.genres", value: genres.map { $0.name }.joined(separator: ", ")))
        }

        if let runtime = tvShow.formattedEpisodeRuntime {
            rows.append(Row(titleKey: "movieDetail.runtime", value: runtime))
        }

        if let first = MediaInfoFormatting.formatDate(tvShow.firstAirDate) {
            rows.append(Row(titleKey: "tvDetail.firstAirDate", value: first))
        }

        if let last = MediaInfoFormatting.formatDate(tvShow.lastAirDate) {
            rows.append(Row(titleKey: "tvDetail.lastAirDate", value: last))
        }

        if let status = MediaInfoFormatting.localizedStatus(tvShow.status) {
            rows.append(Row(titleKey: "movieDetail.status", value: status))
        }

        if let seasons = tvShow.numberOfSeasons, seasons > 0 {
            let seasonsText = String(format: "tvDetail.seasonsCount".localized, seasons)
            if let episodes = tvShow.numberOfEpisodes, episodes > 0 {
                let episodesText = String(format: "tvDetail.episodesCount".localized, episodes)
                rows.append(Row(titleKey: "tvDetail.seasonsEpisodes", value: "\(seasonsText) · \(episodesText)"))
            } else {
                rows.append(Row(titleKey: "tvDetail.seasonsEpisodes", value: seasonsText))
            }
        }

        if let networks = tvShow.networks, !networks.isEmpty {
            rows.append(Row(titleKey: "tvDetail.network", value: networks.map(\.name).joined(separator: ", ")))
        }

        if let creators = tvShow.createdBy, !creators.isEmpty {
            rows.append(Row(titleKey: "tvDetail.createdBy", value: creators.map(\.name).joined(separator: ", ")))
        } else if let director {
            rows.append(Row(titleKey: "movieDetail.director", value: director.name))
        }

        if let country = tvShow.productionCountries?.first,
           let name = MediaInfoFormatting.localizedCountry(iso: country.iso, fallback: country.name) {
            rows.append(Row(titleKey: "movieDetail.country", value: name))
        }

        if let tagline = tvShow.tagline, !tagline.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(Row(titleKey: "movieDetail.tagline", value: tagline, isItalic: true))
        }

        return rows
    }
}

/// I formattatori condivisi dalle due sezioni. Puri: nessuno stato, nessuna rete.
enum MediaInfoFormatting {

    /// Fissa il locale usato dai formattatori. Serve ai test, che devono poter verificare più
    /// lingue senza toccare le preferenze dell'utente. `nil` = segui la scelta in-app.
    nonisolated(unsafe) static var localeOverride: Locale?

    /// Il locale con cui Foundation deve tradurre date, paesi e lingue.
    ///
    /// È quello della lingua **scelta in-app**, non `Locale.current`: su un iPhone in inglese con
    /// VibeWatch in italiano queste righe tornavano in inglese, e la scheda risultava mezza
    /// tradotta. Calcolato a ogni accesso, non memorizzato, così cambiare lingua dalle
    /// impostazioni si vede subito senza riavviare l'app.
    nonisolated static var displayLocale: Locale {
        localeOverride ?? LocalizationManager.shared.appLocale
    }

    /// "2024-05-17" → data lunga nella lingua dell'utente. Nil se la stringa non è una data.
    static func formatDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return nil }

        let printer = DateFormatter()
        printer.locale = displayLocale
        printer.dateStyle = .long
        printer.timeStyle = .none
        return printer.string(from: date)
    }

    /// "GB" → "Regno Unito". Nil solo se non resta niente da mostrare.
    ///
    /// TMDB manda `production_countries[].name` **sempre in inglese**, anche con `language=it-IT`:
    /// la riga "Paese" diceva "United Kingdom" in ogni lingua. Il codice ISO che accompagna il
    /// nome, invece, lo traduce iOS. Il nome TMDB resta come rete di sicurezza per i (rari) codici
    /// che Foundation non riconosce.
    static func localizedCountry(iso: String?, fallback: String?) -> String? {
        let cleanFallback = fallback?.trimmingCharacters(in: .whitespaces)
        guard let iso, !iso.isEmpty else {
            return (cleanFallback?.isEmpty == false) ? cleanFallback : nil
        }
        if let name = displayLocale.localizedString(forRegionCode: iso), name != iso {
            return name
        }
        return (cleanFallback?.isEmpty == false) ? cleanFallback : iso
    }

    /// 185_000_000 → "$185M". Zero e nil valgono "dato assente": TMDB usa 0 per "non lo so".
    static func formatCurrencyCompact(_ amount: Int?) -> String? {
        guard let amount, amount > 0 else { return nil }

        let value = Double(amount)
        switch value {
        case 1_000_000_000...:
            return "$" + trim(value / 1_000_000_000) + "B"
        case 1_000_000...:
            return "$" + trim(value / 1_000_000) + "M"
        case 1_000...:
            return "$" + trim(value / 1_000) + "K"
        default:
            return "$\(amount)"
        }
    }

    /// "en" → "English"/"Inglese". Nil se il codice non è riconosciuto.
    static func localizedLanguage(_ code: String?) -> String? {
        guard let code, !code.isEmpty,
              let name = displayLocale.localizedString(forLanguageCode: code),
              name != code else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Gli stati TMDB arrivano in inglese: qui diventano una chiave localizzata, e restano
    /// tali e quali se è uno stato che non conosciamo (meglio l'inglese del nulla).
    static func localizedStatus(_ status: String?) -> String? {
        guard let status, !status.isEmpty else { return nil }
        let key: String?
        switch status.lowercased() {
        case "released": key = "mediaStatus.released"
        case "in production": key = "mediaStatus.inProduction"
        case "post production": key = "mediaStatus.postProduction"
        case "planned": key = "mediaStatus.planned"
        case "rumored": key = "mediaStatus.rumored"
        case "canceled", "cancelled": key = "mediaStatus.canceled"
        case "returning series": key = "mediaStatus.returningSeries"
        case "ended": key = "mediaStatus.ended"
        case "pilot": key = "mediaStatus.pilot"
        default: key = nil
        }
        guard let key else { return status }
        return key.localized
    }

    private static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }
}
