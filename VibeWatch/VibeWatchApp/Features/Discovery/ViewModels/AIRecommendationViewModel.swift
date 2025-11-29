import Foundation
import SwiftUI

@MainActor
class AIRecommendationViewModel: ObservableObject {
    @Published var prompt: String = ""
    @Published var responseText: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String?
    
    // Pre-defined suggestions to help the user get started
    let suggestionChips = [
        "Sad movie in space",
        "80s action comedy",
        "Hidden gem thriller",
        "Cyberpunk anime",
        "Feel-good romance"
    ]
    
    func getRecommendations() async {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        isLoading = true
        error = nil
        responseText = "" // Clear previous response or keep it? Let's clear it to show fresh loading state.
        
        do {
            // We append a specific instruction to format the output
            let fullPrompt = """
            Recommend 3-5 movies or TV shows based on this request: "\(prompt)".
            For each recommendation, provide:
            1. Title
            2. Year
            3. A brief 1-sentence reason why it fits.
            
            Format the output clearly.
            """
            
            let result = try await CerebrasService.shared.generateResponse(prompt: fullPrompt)
            responseText = result
        } catch {
            self.error = "Failed to get recommendations. Please try again."
            print("AI Error: \(error)")
        }
        
        isLoading = false
    }
    
    func applySuggestion(_ suggestion: String) {
        prompt = suggestion
    }
}
