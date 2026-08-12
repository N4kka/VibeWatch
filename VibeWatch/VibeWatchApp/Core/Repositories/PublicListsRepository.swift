import Foundation

/// Sorgente read-only delle liste pubbliche (pipeline separata dall'offline-first delle liste
/// possedute). Iniettabile per testare `PublicListsViewModel` senza rete.
@MainActor
protocol PublicListsProviding {
    /// Feed paginato (Explore/Followed) con ricerca parziale lato server.
    func fetchPublicLists(search: String?, scope: PublicListsScope, limit: Int, offset: Int) async throws -> [PublicList]
    /// Item di una lista pubblica (riusa `get_list_items_with_providers`, ora guard owner OR public).
    func fetchPublicListItems(listId: String) async throws -> [MediaListItem]
}

/// Implementazione che delega a `SupabaseService`.
@MainActor
final class PublicListsRepository: PublicListsProviding {
    private let remote: SupabaseService

    init(remote: SupabaseService = .shared) {
        self.remote = remote
    }

    func fetchPublicLists(search: String?, scope: PublicListsScope, limit: Int, offset: Int) async throws -> [PublicList] {
        try await remote.fetchPublicLists(search: search, scope: scope, limit: limit, offset: offset)
    }

    func fetchPublicListItems(listId: String) async throws -> [MediaListItem] {
        try await remote.fetchListItems(listId: listId)
    }
}
