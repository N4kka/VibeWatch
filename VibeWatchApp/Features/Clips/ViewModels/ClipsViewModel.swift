import Foundation
import SwiftUI

@MainActor
class ClipsViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    func loadClips() async {
        isLoading = true
        errorMessage = nil
        
        // TODO: Load clips from Supabase/API
        // For now, using mock data
        clips = []
        
        isLoading = false
    }
}
