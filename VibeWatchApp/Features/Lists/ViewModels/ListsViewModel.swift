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

    func createList(title: String, description: String?) async {
        guard !title.isEmpty else {
            errorMessage = "List title cannot be empty"
            return
        }

        // Create list via ListManager (saves to UserDefaults)
        listManager.createList(name: title, description: description)

        // Lists are automatically updated via the publisher binding
    }

    func deleteList(_ list: MediaList) async {
        // Delete from ListManager
        listManager.deleteList(list)

        // Lists are automatically updated via the publisher binding
    }
}
