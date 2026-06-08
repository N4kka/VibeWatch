import Foundation
import SwiftUI
import Combine

@MainActor
class ListsViewModel: ObservableObject {
    @Published var lists: [MediaList] = []
    @Published var isLoading = false
    @Published var isLoadingInitial = true
    @Published var error: AppError?

    // Default list derivate dallo stream osservato (`lists` contiene anche le core list).
    var watchlist: MediaList { lists.first { $0.type == .watchlist } ?? MediaList(name: ListType.watchlist.rawValue, type: .watchlist) }
    var seenList: MediaList { lists.first { $0.type == .seen } ?? MediaList(name: ListType.seen.rawValue, type: .seen) }
    var likedList: MediaList { lists.first { $0.type == .liked } ?? MediaList(name: ListType.liked.rawValue, type: .liked) }
    var dislikedList: MediaList { lists.first { $0.type == .disliked } ?? MediaList(name: ListType.disliked.rawValue, type: .disliked) }
    var customLists: [MediaList] { lists.filter { $0.type == .custom } }

    private let repository: ListsRepository
    private var observationTask: Task<Void, Never>?

    init(repository: ListsRepository) {
        self.repository = repository
        // La View osserva il repository (strangler-fig): stream del local store.
        observationTask = Task { [weak self] in
            for await lists in repository.observe() {
                self?.lists = lists
            }
        }
    }

    /// Back-compat per i call-site esistenti che iniettano un ListManager.
    convenience init(listManager: ListManager = .shared) {
        self.init(repository: ListManagerListsRepository(manager: listManager))
        // Seed SINCRONO dallo stato corrente del manager: ListsView viene distrutta/ricreata a
        // ogni cambio tab (MainTabView usa `if selectedTab == 3 { ListsView() }`), quindi a ogni
        // ingresso nasce un nuovo ViewModel. Senza seed, `isLoadingInitial` parte da `true` (default)
        // e `lists` da `[]`, e si vedono per un frame il ProgressView / l'empty-state prima che lo
        // stream e il binding consegnino i valori → glitch di "ricaricamento". Seedando qui i valori
        // correnti, un VM ricreato parte già pronto.
        self.lists = listManager.lists
        self.isLoadingInitial = listManager.isLoadingInitial
        // Lo stato di caricamento iniziale è una concern UI: lo riflettiamo dal manager.
        listManager.$isLoadingInitial.assign(to: &$isLoadingInitial)
    }

    deinit {
        observationTask?.cancel()
    }

    func loadLists() async {
        // Le liste arrivano già dallo stream del repository (observe()).
        isLoading = false
    }

    func canCreateList() -> Bool {
        repository.canCreateList()
    }

    func createList(title: String, description: String?) async throws {
        try await repository.createList(name: title, description: description)
    }

    func deleteList(_ list: MediaList) async throws {
        try await repository.deleteList(id: list.id)
    }

    func addToList(listId: String, movie: Movie, mediaType: MediaType) async throws {
        try await repository.addToList(listId: listId, movie: movie, mediaType: mediaType)
    }

    func removeFromList(listId: String, itemId: String) async throws {
        try await repository.removeFromList(listId: listId, itemId: itemId)
    }
}
