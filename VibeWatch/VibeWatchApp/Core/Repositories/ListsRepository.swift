import Foundation
import Combine

/// Repository offline-first per le liste (Fase 2 — strangler-fig).
///
/// NON reimplementa la persistenza: AVVOLGE il `ListManager` funzionante (già offline-first
/// e protetto dai test di caratterizzazione). Le letture sono uno stream del local store;
/// le scritture delegano a `ListManager`. Quando il dual-write verrà rimosso (task #6),
/// cambierà solo l'interno di `ListManager`, non questo contratto: le View restano stabili.
@MainActor
protocol ListsRepository {
    /// Stream delle liste dal local store: emette subito lo stato corrente e poi ad ogni cambiamento.
    func observe() -> AsyncStream<[MediaList]>

    @discardableResult
    func createList(name: String, description: String?) async throws -> MediaList
    func deleteList(id: String) async throws
    func addToList(listId: String, movie: Movie, mediaType: MediaType) async throws
    func removeFromList(listId: String, itemId: String) async throws

    /// Se l'utente può creare un'altra lista custom (limite tier).
    func canCreateList() -> Bool
}

/// Implementazione che delega al `ListManager` esistente.
@MainActor
final class ListManagerListsRepository: ListsRepository {

    private let manager: ListManager

    init(manager: ListManager = .shared) {
        self.manager = manager
    }

    func observe() -> AsyncStream<[MediaList]> {
        AsyncStream { continuation in
            // Stato corrente immediato, poi ogni aggiornamento pubblicato da ListManager.
            continuation.yield(manager.lists)
            let cancellable = manager.$lists.sink { lists in
                continuation.yield(lists)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    @discardableResult
    func createList(name: String, description: String?) async throws -> MediaList {
        try await manager.createList(name: name, description: description)
    }

    func deleteList(id: String) async throws {
        try await manager.deleteList(id: id)
    }

    func addToList(listId: String, movie: Movie, mediaType: MediaType) async throws {
        try await manager.addToList(listId: listId, movie: movie, mediaType: mediaType)
    }

    func removeFromList(listId: String, itemId: String) async throws {
        try await manager.removeFromList(listId: listId, itemId: itemId)
    }

    func canCreateList() -> Bool {
        manager.canCreateList()
    }
}
