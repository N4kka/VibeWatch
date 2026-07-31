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

    init?(json: [String: Any]) {
        guard json["found"] as? Bool == true,
              let profile = PublicProfile(json: json) else { return nil }
        self.profile = profile
        self.followers = json["followers"] as? Int ?? 0
        self.following = json["following"] as? Int ?? 0
        self.isFollowing = json["is_following"] as? Bool ?? false
        self.followsMe = json["follows_me"] as? Bool ?? false
    }

    init(profile: PublicProfile, followers: Int, following: Int,
         isFollowing: Bool, followsMe: Bool) {
        self.profile = profile
        self.followers = followers
        self.following = following
        self.isFollowing = isFollowing
        self.followsMe = followsMe
    }
}
