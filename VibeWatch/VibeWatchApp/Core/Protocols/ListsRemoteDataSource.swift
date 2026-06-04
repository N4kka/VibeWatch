import Foundation

/// Role-protocol ristretto (interface segregation) con il solo accesso remoto alle liste
/// che serve a `ListManager`. Consente di iniettare un mock nei test del sync-path
/// (es. `syncListsForAuthenticatedUser`) senza toccare la rete.
///
/// `SupabaseService` vi conforma via extension vuota (espone già tutti i membri).
@MainActor
protocol ListsRemoteDataSource: AnyObject {
    var currentUser: User? { get }
    func fetchLists() async throws -> [MediaList]
    func fetchListItems(listId: String) async throws -> [MediaListItem]
    func createList(id: String, name: String, description: String?, type: ListType) async throws -> MediaList
}

extension SupabaseService: ListsRemoteDataSource {}
