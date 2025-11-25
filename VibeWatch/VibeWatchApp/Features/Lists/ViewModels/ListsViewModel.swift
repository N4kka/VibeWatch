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
        listManager.loadLists()
        lists = listManager.lists
        do {
            try await listManager.fetchLists()
            lists = listManager.lists
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func createList(title: String, description: String?) async throws {
        try await listManager.createList(name: title, description: description)
    }

    func deleteList(_ list: MediaList) async throws {
        try await listManager.deleteList(id: list.id)
    }
}
