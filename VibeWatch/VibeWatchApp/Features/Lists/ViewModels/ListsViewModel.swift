import Foundation
import SwiftUI
import Combine

@MainActor
class ListsViewModel: ObservableObject {
    @Published var lists: [MediaList] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let listManager = ListManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Observe ListManager changes to keep lists in sync
        listManager.$lists
            .assign(to: &$lists)
    }

    func loadLists() async {
        isLoading = true
        errorMessage = nil

        // Load from ListManager (local UserDefaults storage)
        listManager.loadLists()
        lists = listManager.lists

        isLoading = false
    }

    func createList(title: String, description: String?) async -> Result<Void, ListError> {
        guard !title.isEmpty else {
            errorMessage = "List title cannot be empty"
            return .failure(.listNotFound) // Reusing error type
        }

        // Create list via ListManager (saves to UserDefaults)
        let result = listManager.createList(name: title, description: description)
        
        switch result {
        case .success:
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }

        // Lists are automatically updated via the publisher binding
        return result
    }

    func deleteList(_ list: MediaList) async {
        // Delete from ListManager
        listManager.deleteList(list)

        // Lists are automatically updated via the publisher binding
    }
}
