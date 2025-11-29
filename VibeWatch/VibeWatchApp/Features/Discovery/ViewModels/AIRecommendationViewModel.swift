import Foundation
import SwiftUI

struct AIMessage: Identifiable, Equatable {
    let id = UUID()
    var content: String
    let isUser: Bool
    var isEditing: Bool = false
}

@MainActor
class AIRecommendationViewModel: ObservableObject {
    @Published var prompt: String = ""
    @Published var messages: [AIMessage] = []
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
    
    func sendMessage() async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        
        // Add user message
        let userMessage = AIMessage(content: trimmedPrompt, isUser: true)
        messages.append(userMessage)
        prompt = "" // Clear input
        
        await generateResponse(for: trimmedPrompt)
    }
    
    func regenerateResponse(for messageId: UUID, newContent: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        
        // Update user message
        messages[index].content = newContent
        messages[index].isEditing = false
        
        // Remove all subsequent messages (previous AI response)
        if index + 1 < messages.count {
            messages.removeSubrange((index + 1)...)
        }
        
        await generateResponse(for: newContent)
    }
    
    private func generateResponse(for query: String) async {
        isLoading = true
        error = nil
        
        do {
            // We append a specific instruction to format the output
            let fullPrompt = """
            Recommend 3-5 movies or TV shows based on this request: "\(query)".
            For each recommendation, provide:
            1. Title
            2. Year
            3. A brief 1-sentence reason why it fits.
            
            Format the output clearly.
            """
            
            let result = try await CerebrasService.shared.generateResponse(prompt: fullPrompt)
            let aiMessage = AIMessage(content: result, isUser: false)
            messages.append(aiMessage)
        } catch {
            self.error = "Failed to get recommendations. Please try again."
            print("AI Error: \(error)")
        }
        
        isLoading = false
    }
    
    func applySuggestion(_ suggestion: String) {
        prompt = suggestion
    }
    
    func toggleEdit(for messageId: UUID) {
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].isEditing.toggle()
        }
    }
}
