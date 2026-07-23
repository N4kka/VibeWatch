import Foundation

/// La mappa canonica id→nome dei generi TMDB.
///
/// Era duplicata carattere per carattere in `DatabaseClipsService` e `ClipsPrefetchService`
/// (ARCH-008). Altri file tengono mappe *diverse* (mood, sottoinsiemi): quelle restano dove sono
/// finché non si dimostra che sono lo stesso dato — questo helper unifica solo le due identiche.
enum TMDBGenres {
    static let idToName: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
        80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
        14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Sci-Fi", 10770: "TV Movie",
        53: "Thriller", 10752: "War", 37: "Western"
    ]

    static func name(for id: Int) -> String? { idToName[id] }
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
