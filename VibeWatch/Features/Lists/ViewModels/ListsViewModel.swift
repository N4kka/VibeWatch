import Foundation
import SwiftUI

@MainActor
class ListsViewModel: ObservableObject {
    @Published var lists: [MediaList] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    func loadLists() async {
        isLoading = true
        errorMessage = nil
        
        // TODO: Load lists from Supabase
        // For now, using empty array
        lists = []
        
        isLoading = false
    }
    
    func createList(title: String, description: String?) async {
        // TODO: Create list in Supabase
    }
    
    func deleteList(_ list: MediaList) async {
        // TODO: Delete list from Supabase
    }
}
