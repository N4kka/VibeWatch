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
/// Autore anonimo in Fase 1 (i nickname arrivano in Fase 2).
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
}
