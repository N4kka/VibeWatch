import Foundation
import SwiftUI
import Combine

@MainActor
class ListsViewModel: ObservableObject {
    @Published var lists: [MediaList] = []
    @Published var isLoading = false
    @Published var error: AppError?

    private let listManager: ListManager
    private var cancellables = Set<AnyCancellable>()

    init(listManager: ListManager = .shared) {
        self.listManager = listManager
        // Observe ListManager changes to keep lists in sync
        listManager.$lists
            .assign(to: &$lists)
    }

    func loadLists() async {
        // No need to reload - ViewModel already observes listManager.$lists
        // which automatically updates when lists change
        
        // Just mark as loaded
        isLoading = false
        
        // Lists are already synced via the Combine publisher (line 16-17)
        // Any changes to listManager.lists automatically update this.lists
    }

    func createList(title: String, description: String?) async throws {
        try await listManager.createList(name: title, description: description)
    }

    func deleteList(_ list: MediaList) async throws {
        try await listManager.deleteList(id: list.id)
    }
}
