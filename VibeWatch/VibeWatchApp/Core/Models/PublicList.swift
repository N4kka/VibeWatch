import Foundation

/// Filtro del feed delle liste pubbliche (pillola JustWatch-style).
enum PublicListsScope: String, CaseIterable {
    case explore
    case followed

    var localizationKey: String {
        switch self {
        case .explore: return "lists.public.scope.explore"
        case .followed: return "lists.public.scope.followed"
        }
    }
}

/// Lista pubblica altrui (remota, sola lettura). Distinta da `MediaList` (liste possedute,
/// offline-first): qui non carichiamo gli item nel feed, solo i metadati + le cover.
/// L'autore non è più anonimo (social feed M1): `get_public_lists` porta i quattro campi owner.
struct PublicList: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
    let type: ListType
    let itemCount: Int
    /// Fino a 4 poster (ultimi item) per la cover a griglia, riusa il rendering di `ListCard`.
    let coverPosterPaths: [String]
    let followerCount: Int
    let updatedAt: Date?
    var isFollowing: Bool
    /// Owner opzionali, non per pigrizia: un server non ancora migrato non manda le colonne e
    /// il feed deve restare leggibile — la card torna semplicemente anonima.
    let ownerId: String?
    let ownerUsername: String?
    let ownerDisplayName: String?
    let ownerAvatarUrl: String?

    /// Init esplicito con gli owner in coda e a default nil: i chiamanti pre-M1 (e i test)
    /// costruiscono la lista come sempre.
    init(id: String, name: String, description: String?, type: ListType, itemCount: Int,
         coverPosterPaths: [String], followerCount: Int, updatedAt: Date?, isFollowing: Bool,
         ownerId: String? = nil, ownerUsername: String? = nil,
         ownerDisplayName: String? = nil, ownerAvatarUrl: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.itemCount = itemCount
        self.coverPosterPaths = coverPosterPaths
        self.followerCount = followerCount
        self.updatedAt = updatedAt
        self.isFollowing = isFollowing
        self.ownerId = ownerId
        self.ownerUsername = ownerUsername
        self.ownerDisplayName = ownerDisplayName
        self.ownerAvatarUrl = ownerAvatarUrl
    }
}
