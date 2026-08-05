import Foundation

/// La mappa canonica id→nome dei generi TMDB.
///
/// Era duplicata carattere per carattere in `DatabaseClipsService` e `ClipsPrefetchService`
/// (ARCH-008). Altri file tengono mappe *diverse* (mood, sottoinsiemi): quelle restano dove sono
/// finché non si dimostra che sono lo stesso dato — questo helper unifica solo le due identiche.
///
/// Due nomi per lo stesso genere, e servono entrambi:
/// - `name(for:)` è il nome **canonico inglese**. Va nei prompt AI, nei log e nelle chiavi di
///   deduplica, dove il testo deve restare stabile qualunque lingua abbia scelto l'utente.
/// - `localizedName(for:)` è il nome da **mostrare**. Tutto ciò che finisce a schermo passa di qui,
///   altrimenti si ottengono titoli ibridi come "Il meglio di Science Fiction".
enum TMDBGenres {
    static let idToName: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
        80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
        14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Science Fiction", 10770: "TV Movie",
        53: "Thriller", 10752: "War", 37: "Western",
        // I generi che TMDB usa SOLO per le serie TV: `tmdb_shows.genres` (§9.3, stats
        // avanzate) li contiene, e senza questi otto una ripartizione per genere mostrerebbe
        // "#10765" al posto di Sci-Fi & Fantasy.
        10759: "Action & Adventure", 10762: "Kids", 10763: "News", 10764: "Reality",
        10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk", 10768: "War & Politics"
    ]

    /// id→slug della chiave in `Localizable.strings` (`genre.<slug>`).
    ///
    /// Slug e non id numerico perché queste chiavi le leggono e le traducono degli umani: in un
    /// file di 1000 righe `"genre.scienceFiction"` si verifica a colpo d'occhio, `"genre.878"` no.
    private static let idToSlug: [Int: String] = [
        28: "action", 12: "adventure", 16: "animation", 35: "comedy",
        80: "crime", 99: "documentary", 18: "drama", 10751: "family",
        14: "fantasy", 36: "history", 27: "horror", 10402: "music",
        9648: "mystery", 10749: "romance", 878: "scienceFiction", 10770: "tvMovie",
        53: "thriller", 10752: "war", 37: "western",
        10759: "actionAdventure", 10762: "kids", 10763: "news", 10764: "reality",
        10765: "sciFiFantasy", 10766: "soap", 10767: "talk", 10768: "warPolitics"
    ]

    static func name(for id: Int) -> String? { idToName[id] }

    /// Il nome del genere nella lingua scelta in-app. `nil` per un id sconosciuto, così il
    /// chiamante decide se mostrare un fallback o saltare del tutto la sezione.
    static func localizedName(for id: Int) -> String? {
        guard let slug = idToSlug[id] else { return nil }
        let key = "genre.\(slug)"
        let localized = key.localized
        // `.localized` restituisce la chiave stessa quando manca ovunque: in quel caso è meglio il
        // nome inglese canonico di una stringa che a schermo si legge "genre.action".
        return localized == key ? idToName[id] : localized
    }

    /// Variante comoda per i punti in cui un nome va comunque mostrato: prova la traduzione,
    /// poi l'inglese canonico, infine l'id grezzo.
    static func displayName(for id: Int) -> String {
        localizedName(for: id) ?? idToName[id] ?? "#\(id)"
    }
}

/// La data di installazione dell'app, persistita in `UserDefaults`.
///
/// Anch'essa era duplicata nei due servizi clip. Nota di comportamento preservata dall'originale:
/// alla prima lettura la fissa a **ieri**, così il conteggio-giorni parte da 1 e non da 0.
enum AppInstall {
    static var date: Date {
        let key = "appInstallDate"
        if let existing = UserDefaults.standard.object(forKey: key) as? Date {
            return existing
        }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        UserDefaults.standard.set(yesterday, forKey: key)
        return yesterday
    }
}
