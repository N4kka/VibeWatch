import Foundation

/// Una riga di `search_users`: le sei colonne di `public_profiles`, niente di più.
/// L'email e i campi di billing non arrivano qui per costruzione (§3.7), non per disciplina.
struct PublicProfile: Identifiable, Equatable {
    let id: String
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let bio: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let username = json["username"] as? String else { return nil }
        self.id = id
        self.username = username
        self.displayName = json["display_name"] as? String
        self.avatarUrl = json["avatar_url"] as? String
        self.bio = json["bio"] as? String
    }

    init(id: String, username: String, displayName: String? = nil,
         avatarUrl: String? = nil, bio: String? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.bio = bio
    }
}

/// Uno slot dei favorites di §9.3: posizione e id TMDB, nient'altro — titolo e poster sono
/// catalogo pubblico e li risolve il client.
struct FavoriteSlot: Equatable, Identifiable {
    let slot: Int
    let tmdbId: Int

    var id: Int { slot }

    init?(json: [String: Any]) {
        guard let slot = json["slot"] as? Int, let tmdbId = json["tmdb_id"] as? Int else {
            return nil
        }
        self.slot = slot
        self.tmdbId = tmdbId
    }

    init(slot: Int, tmdbId: Int) {
        self.slot = slot
        self.tmdbId = tmdbId
    }
}

/// L'esito di `get_public_profile`: profilo, contatori e relazione col chiamante.
///
/// L'`init` restituisce `nil` su `found: false` **e** su una risposta che non si capisce con
/// `found` assente: un profilo senza conferma esplicita di esistenza non si mostra. La lezione
/// di `username_available` — un errore spacciato per risposta — qui non può ripetersi perché
/// il chiamante distingue: `nil` è "non esiste", l'errore di rete resta un `throw`.
struct PublicProfileDetail: Equatable {
    let profile: PublicProfile
    let followers: Int
    let following: Int
    var isFollowing: Bool
    let followsMe: Bool
    let favoriteMovies: [FavoriteSlot]
    let favoriteShows: [FavoriteSlot]

    init?(json: [String: Any]) {
        guard json["found"] as? Bool == true,
              let profile = PublicProfile(json: json) else { return nil }
        self.profile = profile
        self.followers = json["followers"] as? Int ?? 0
        self.following = json["following"] as? Int ?? 0
        self.isFollowing = json["is_following"] as? Bool ?? false
        self.followsMe = json["follows_me"] as? Bool ?? false
        let favorites = json["favorites"] as? [String: Any] ?? [:]
        self.favoriteMovies = ((favorites["movie"] as? [[String: Any]]) ?? [])
            .compactMap(FavoriteSlot.init(json:))
        self.favoriteShows = ((favorites["tv"] as? [[String: Any]]) ?? [])
            .compactMap(FavoriteSlot.init(json:))
    }

    init(profile: PublicProfile, followers: Int, following: Int,
         isFollowing: Bool, followsMe: Bool,
         favoriteMovies: [FavoriteSlot] = [], favoriteShows: [FavoriteSlot] = []) {
        self.profile = profile
        self.followers = followers
        self.following = following
        self.isFollowing = isFollowing
        self.followsMe = followsMe
        self.favoriteMovies = favoriteMovies
        self.favoriteShows = favoriteShows
    }
}

/// L'esito di `get_my_stats` (§9.3/§13.7): aggregati del server, mai somme fatte in locale —
/// in cache c'è solo un anno di eventi, e una somma dal client direbbe un numero sbagliato con
/// la faccia di uno giusto.
struct UserStats: Equatable {
    /// §9.3/§10: una fetta delle ripartizioni avanzate (Pro). L'ordinamento è del server e
    /// non si riordina qui: il client mostra.
    struct GenreSlice: Equatable {
        let genreId: Int
        let shows: Int
        let seconds: Int
    }

    struct DecadeSlice: Equatable {
        let decade: Int
        let shows: Int
        let seconds: Int
    }

    struct RatingBucket: Equatable {
        let rating: Int
        let count: Int
    }

    let watchTimeSeconds: Int
    let episodesWatched: Int
    let showsWatched: Int
    let moviesWatched: Int
    let ratingsGiven: Int
    /// §9.3/§10 (Pro): ripartizioni su base catalogo, pesate in secondi VERI (§13.7).
    let perGenere: [GenreSlice]
    let perDecade: [DecadeSlice]
    let votiDistribuzione: [RatingBucket]
    /// Le serie viste il cui catalogo non ha (ancora) i generi: dichiarate, non sparite.
    let showsSenzaGenere: Int

    init?(json: [String: Any]) {
        // Senza il tempo la risposta non è una risposta: meglio un nil che il chiamante tratta
        // da errore che un pannello di zeri spacciati per "non hai visto niente".
        guard let time = json["watch_time_seconds"] as? Int else { return nil }
        self.watchTimeSeconds = time
        self.episodesWatched = json["episodes_watched"] as? Int ?? 0
        self.showsWatched = json["shows_watched"] as? Int ?? 0
        self.moviesWatched = json["movies_watched"] as? Int ?? 0
        self.ratingsGiven = json["ratings_given"] as? Int ?? 0
        self.perGenere = (json["per_genere"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["genre_id"] as? Int else { return nil }
            return GenreSlice(genreId: id, shows: row["shows"] as? Int ?? 0,
                              seconds: row["seconds"] as? Int ?? 0)
        }
        self.perDecade = (json["per_decade"] as? [[String: Any]] ?? []).compactMap { row in
            guard let decade = row["decade"] as? Int else { return nil }
            return DecadeSlice(decade: decade, shows: row["shows"] as? Int ?? 0,
                               seconds: row["seconds"] as? Int ?? 0)
        }
        self.votiDistribuzione = (json["voti_distribuzione"] as? [[String: Any]] ?? [])
            .compactMap { row in
                guard let rating = row["rating"] as? Int else { return nil }
                return RatingBucket(rating: rating, count: row["count"] as? Int ?? 0)
            }
        self.showsSenzaGenere = json["shows_senza_genere"] as? Int ?? 0
    }

    init(watchTimeSeconds: Int, episodesWatched: Int, showsWatched: Int,
         moviesWatched: Int, ratingsGiven: Int,
         perGenere: [GenreSlice] = [], perDecade: [DecadeSlice] = [],
         votiDistribuzione: [RatingBucket] = [], showsSenzaGenere: Int = 0) {
        self.watchTimeSeconds = watchTimeSeconds
        self.episodesWatched = episodesWatched
        self.showsWatched = showsWatched
        self.moviesWatched = moviesWatched
        self.ratingsGiven = ratingsGiven
        self.perGenere = perGenere
        self.perDecade = perDecade
        self.votiDistribuzione = votiDistribuzione
        self.showsSenzaGenere = showsSenzaGenere
    }
}
