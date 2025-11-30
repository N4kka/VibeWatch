import Foundation
import SwiftUI
import NaturalLanguage // Import NaturalLanguage for NLLanguageRecognizer

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
    
    // Token Quota Management
    @Published var tokensUsedToday: Int = 0
    let aiTokenLimit = 8000
    var tokensRemaining: Int { aiTokenLimit - tokensUsedToday }
    var softLimitReached: Bool { tokensUsedToday >= Int(Double(aiTokenLimit) * 0.75) && tokensUsedToday < aiTokenLimit }
    var hardLimitReached: Bool { tokensUsedToday >= aiTokenLimit }
    
    // Dependencies
    private let authService = AuthService.shared
    private let supabaseService = SupabaseService.shared
    private let quotaManager = DailyQuotaManager.shared
    private let languageDetector = LanguageDetector.shared // New: Language Detector
    
    // Pre-defined suggestions to help the user get started
    let suggestionChips = [
        "Sad movie in space",
        "80s action comedy",
        "Hidden gem thriller",
        "Cyberpunk anime",
        "Feel-good romance"
    ]
    
    init() {
        // Fetch token usage on init
        Task { await fetchDailyTokenUsage() }
    }
    
    func fetchDailyTokenUsage() async {
        guard let userId = authService.currentUser?.id else {
            tokensUsedToday = 0 // Reset if not logged in
            return
        }
        do {
            tokensUsedToday = try await supabaseService.getAITokenUsage(userId: UUID(uuidString: userId)!)
        } catch {
            print("❌ Failed to fetch daily AI token usage: \(error)")
            self.error = "Failed to load token usage."
        }
    }
    
    func sendMessage() async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        
        // --- PRO Check & Quota Enforcement ---
        guard authService.isAuthenticated else {
            self.error = "auth.gate.authRequiredAI".localized // New key needed
            return
        }
        guard quotaManager.isProUser else {
            self.error = "ai.proRequired".localized // New key needed
            return
        }
        guard !hardLimitReached else {
            self.error = "ai.hardLimitMessage".localized
            return
        }
        
        // Pre-flight token estimation (approximate)
        let estimatedTokensForTurn = trimmedPrompt.count / 4 + 200 // ~4 chars per token + ~200 for AI response
        guard tokensRemaining >= estimatedTokensForTurn else {
            self.error = "ai.hardLimitMessage".localized
            return
        }
        
        // Add user message
        let userMessage = AIMessage(content: trimmedPrompt, isUser: true)
        messages.append(userMessage)
        prompt = "" // Clear input
        
        await generateResponse(for: trimmedPrompt)
    }
    
    func regenerateResponse(for messageId: UUID, newContent: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        
        // --- PRO Check & Quota Enforcement ---
        guard authService.isAuthenticated else {
            self.error = "auth.gate.authRequiredAI".localized
            return
        }
        guard quotaManager.isProUser else {
            self.error = "ai.proRequired".localized
            return
        }
        guard !hardLimitReached else {
            self.error = "ai.hardLimitMessage".localized
            return
        }
        
        // Pre-flight token estimation (approximate)
        let estimatedTokensForTurn = newContent.count / 4 + 200 // ~4 chars per token + ~200 for AI response
        guard tokensRemaining >= estimatedTokensForTurn else {
            self.error = "ai.hardLimitMessage".localized
            return
        }
        
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
            // Detect the user's language and instruct the model to mirror it
            let detectedLangCode = languageDetector.detectLanguage(for: query)
            let detectedLanguageDescription: String
            if let langCode = detectedLangCode,
               let localizedName = Locale.current.localizedString(forLanguageCode: langCode) {
                detectedLanguageDescription = "\(localizedName) (\(langCode))"
            } else {
                detectedLanguageDescription = "the user's language"
            }
            
            let languageInstruction = """
            Always respond in the same language as the user's request. Detected language: \(detectedLanguageDescription). Do not translate the user's intent into another language.
            """
            
            let systemPromptWithLanguage = "You are a helpful assistant for a movie and TV show discovery app called VibeWatch. \(languageInstruction)"
            
            let fullPrompt = """
            Recommend 3-5 movies or TV shows based on this request: "\(query)".
            For each recommendation, provide:
            1. Title
            2. Year
            3. A brief 1-sentence reason why it fits.
            
            Format the output clearly.
            """
            
            let cerebrasResponse = try await CerebrasService.shared.generateResponse(
                prompt: fullPrompt,
                systemPrompt: systemPromptWithLanguage // Use dynamic system prompt
            )
            let aiMessage = AIMessage(content: cerebrasResponse.choices.first?.message.content ?? "No response", isUser: false)
            messages.append(aiMessage)
            
            // Log token usage
            if let totalTokens = cerebrasResponse.usage?.totalTokens,
               let userId = authService.currentUser?.id {
                #if DEBUG
                print("ℹ️ [Debug] Skipping Supabase AI token log (totalTokens=\(totalTokens))")
                #else
                do {
                    let updatedTotal = try await supabaseService.logAITokenUsage(userId: UUID(uuidString: userId)!, tokensConsumed: totalTokens)
                    tokensUsedToday = updatedTotal
                    print("✅ AI Tokens used today: \(tokensUsedToday)/\(aiTokenLimit)")
                } catch {
                    // Logging failure should not block responses; just report and continue
                    print("⚠️ Failed to log AI token usage: \(error)")
                }
                #endif
            }
            
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
