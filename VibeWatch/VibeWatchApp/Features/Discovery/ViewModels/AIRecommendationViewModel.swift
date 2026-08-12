import Foundation
import SwiftUI
import UIKit

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
    
    // Daily Request Quota Management (service is request-based)
    @Published var requestsUsedToday: Int = 0
    @Published private(set) var dailyRequestLimit: Int
    var hardLimitReached: Bool { requestsUsedToday >= dailyRequestLimit }
    
    // Dependencies
    private let authService: AuthService
    private let aiTokenManager: AITokenManager
    private let languageDetector: LanguageDetector
    private let tmdbService: any TMDBServiceProtocol
    private let cerebrasService: CerebrasService
    private let preferenceManager: UserPreferenceManager
    private let queryClassifier: AIQueryClassifier
    private let contextBuilder: AIContextBuilder
    private let conversationMemory: ConversationMemoryManager
    private var timeChangeObserver: NSObjectProtocol?
    private let userDefaults = UserDefaults.standard

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(
        authService: AuthService = .shared,
        aiTokenManager: AITokenManager = .shared,
        languageDetector: LanguageDetector = .shared,
        tmdbService: any TMDBServiceProtocol = TMDBService.shared,
        cerebrasService: CerebrasService = .shared,
        preferenceManager: UserPreferenceManager = .shared,
        queryClassifier: AIQueryClassifier = .shared,
        contextBuilder: AIContextBuilder = .shared,
        conversationMemory: ConversationMemoryManager = .shared
    ) {
        self.authService = authService
        self.aiTokenManager = aiTokenManager
        self.languageDetector = languageDetector
        self.tmdbService = tmdbService
        self.cerebrasService = cerebrasService
        self.preferenceManager = preferenceManager
        self.queryClassifier = queryClassifier
        self.contextBuilder = contextBuilder
        self.conversationMemory = conversationMemory

        // Limit is now managed by AITokenManager (requests)
        self.dailyRequestLimit = aiTokenManager.dailyLimit
        self.requestsUsedToday = aiTokenManager.requestsUsedToday

        startDayChangeMonitoring()
        Task {
            await conversationMemory.loadSessionIfNeeded()
            hydrateMessagesFromMemory()
            // Sync with AITokenManager
            await syncWithTokenManager()
        }
    }

    deinit {
        if let timeChangeObserver {
            NotificationCenter.default.removeObserver(timeChangeObserver)
        }
    }

    private func startDayChangeMonitoring() {
        timeChangeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // AITokenManager handles its own date check, but we can trigger a UI refresh
            Task { @MainActor in
                await self?.syncWithTokenManager()
            }
        }
    }
    
    func updateRequestLimit(isProUser: Bool) {
        aiTokenManager.updateLimit()
        Task { await syncWithTokenManager() }
    }
    
    func fetchDailyRequestUsage() async {
        if let user = authService.currentUser {
            let userIdString = "\(user.id)"
            if let userId = UUID(uuidString: userIdString) {
                if let newTotal = try? await SupabaseService.shared.getAITokenUsage(userId: userId) {
                    aiTokenManager.syncRequests(newTotal)
                }
            }
        }
        await syncWithTokenManager()
    }

    @MainActor
    private func syncWithTokenManager() async {
        self.dailyRequestLimit = aiTokenManager.dailyLimit
        self.requestsUsedToday = aiTokenManager.requestsUsedToday
    }
    
    func sendMessage() async {
        let trimmedPrompt = sanitizeUserPrompt(prompt)
        guard !trimmedPrompt.isEmpty else { return }
        
        // --- PRO Check & Quota Enforcement ---
        guard authService.isAuthenticated else {
            self.error = "auth.gate.authRequiredAI".localized
            return
        }
        
        guard aiTokenManager.canMakeRequest() else {
            self.error = "ai.hardLimitMessage".localized
            return
        }
        
        // Add user message
        let userMessage = AIMessage(content: trimmedPrompt, isUser: true)
        messages.append(userMessage)
        prompt = "" // Clear input

        await conversationMemory.append(role: .user, content: trimmedPrompt)
        
        await generateResponse(for: trimmedPrompt)
    }
    
    func regenerateResponse(for messageId: UUID, newContent: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        
        // --- PRO Check & Quota Enforcement ---
        guard authService.isAuthenticated else {
            self.error = "auth.gate.authRequiredAI".localized
            return
        }
        guard aiTokenManager.canMakeRequest() else {
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

        await conversationMemory.append(role: .user, content: newContent)
        
        await generateResponse(for: newContent)
    }
    
    private func generateResponse(for query: String) async {
        isLoading = true
        error = nil
        
        do {
            let classification = queryClassifier.classify(query: query)
            let profile = await preferenceManager.aggregatePreferences()

            let detectedLangCode = languageDetector.detectLanguage(for: query)
            let languageInstruction = buildLanguageInstruction(detectedLangCode: detectedLangCode)

            let systemPrompt = contextBuilder.buildSystemPrompt(
                userProfile: profile.userId.isEmpty ? nil : profile,
                queryType: classification.type
            ) + "\n\n" + languageInstruction

            let history = conversationHistoryForModel(filteredTo: detectedLangCode)

            let (prompt, metadata) = try await buildPromptAndMetadata(
                query: query,
                classification: classification,
                userProfile: profile,
                conversationHistory: history
            )

            // Switch to Cerebras
            let (content, tokens) = try await cerebrasService.chat(
                history: history,
                prompt: prompt,
                systemPrompt: systemPrompt
            )

            let aiMessage = AIMessage(content: content, isUser: false)
            messages.append(aiMessage)
            
            // Record Usage
            aiTokenManager.recordUsage()
            await syncWithTokenManager()

            await conversationMemory.append(
                role: .assistant,
                content: content,
                queryType: metadata.queryTypeKey,
                mentionedMediaIds: metadata.mentionedMediaIds,
                mentionedGenres: metadata.mentionedGenres,
                tokensUsed: tokens
            )
            
        } catch CerebrasError.quotaExceeded {
            self.error = "ai.hardLimitMessage".localized
        } catch {
            Logger.error("[AIRecommendationViewModel] AI Error", error: error)
            self.error = "Failed to get recommendations. Please try again."
        }
        
        isLoading = false
    }

    // Deprecated
    private func incrementRequestUsage() async { }

    
    func applySuggestion(_ suggestion: String) {
        prompt = suggestion
    }
    
    func sendSuggestion(_ suggestion: String) async {
        prompt = sanitizeUserPrompt(suggestion)
        await sendMessage()
    }
    
    func toggleEdit(for messageId: UUID) {
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].isEditing.toggle()
        }
    }

    // MARK: - Helpers

    private func hydrateMessagesFromMemory() {
        let historical = conversationMemory.recentMessages()
        messages = historical
            .filter { $0.role != .system }
            .map { AIMessage(content: $0.content, isUser: $0.role == .user) }
    }

    private func conversationHistoryForModel() -> [AIChatMessage] {
        let historical = conversationMemory.recentMessages()

        // We already pass the current prompt separately to Chutes; avoid duplicating if the last message is a user prompt.
        if let last = historical.last, last.role == .user {
            return Array(historical.dropLast())
        }
        return historical
    }

    private func conversationHistoryForModel(filteredTo languageCode: String?) -> [AIChatMessage] {
        let base = conversationHistoryForModel()
        guard let languageCode else { return base }

        return base.filter { message in
            if message.role == .system { return true }
            guard let detected = languageDetector.detectLanguage(for: message.content) else { return false }
            return detected == languageCode
        }
    }

    private func buildLanguageInstruction(detectedLangCode: String?) -> String {
        let detectedLanguageDescription: String
        // Il nome della lingua va in inglese perché finisce dentro un prompt in inglese: con
        // `Locale.current` l'istruzione diventava "You MUST respond ONLY in italiano (it)".
        if let langCode = detectedLangCode,
           let localizedName = Locale(identifier: "en_US").localizedString(forLanguageCode: langCode) {
            detectedLanguageDescription = "\(localizedName) (\(langCode))"
        } else {
            detectedLanguageDescription = "the user's last input language"
        }

        return """
        CRITICAL LANGUAGE RULE:
        - You MUST respond ONLY in \(detectedLanguageDescription).
        - Match the user's CURRENT input language exactly.
        - NEVER switch to a different language unless the user does so first in their latest message.
        - If the user's input is in \(detectedLanguageDescription), your entire response MUST be in \(detectedLanguageDescription).
        """
    }

    private func sanitizeUserPrompt(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle chip prefixes like "🤖 AI: ..."
        if let range = cleaned.range(of: "AI:", options: [.caseInsensitive, .anchored]) {
            cleaned.removeSubrange(range)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if cleaned.hasPrefix("🤖") {
            cleaned = cleaned.replacingOccurrences(of: "🤖", with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if cleaned.lowercased().hasPrefix("ai:") {
            cleaned = String(cleaned.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }

    private struct PromptMetadata {
        let queryTypeKey: String?
        let mentionedMediaIds: [Int]
        let mentionedGenres: [String]
    }

    private func buildPromptAndMetadata(
        query: String,
        classification: QueryClassification,
        userProfile: UserProfile,
        conversationHistory: [AIChatMessage]
    ) async throws -> (String, PromptMetadata) {
        switch classification.type {
        case .specificMedia(let title, let mediaTypeHint):
            let (details, mediaId) = try await fetchMediaDetailsForTitle(title, mediaTypeHint: mediaTypeHint)
            let prompt = contextBuilder.buildSpecificMediaPrompt(
                title: title,
                movieDetails: details,
                userProfile: userProfile.userId.isEmpty ? nil : userProfile
            )
            return (
                prompt,
                PromptMetadata(queryTypeKey: "specific_media", mentionedMediaIds: mediaId.map { [$0] } ?? [], mentionedGenres: [])
            )

        case .informational(let question):
            return (
                """
                Answer the user's question clearly and directly:
                \(question)
                """,
                PromptMetadata(queryTypeKey: "informational", mentionedMediaIds: [], mentionedGenres: [])
            )

        case .comparison(let items):
            let itemsText = items.joined(separator: " vs ")
            return (
                """
                Compare these titles and help the user decide: \(itemsText)

                Provide:
                - Quick summary of each
                - Who it's best for
                - Recommendation for the user based on their preferences
                """,
                PromptMetadata(queryTypeKey: "comparison", mentionedMediaIds: [], mentionedGenres: [])
            )

        case .recommendation(let context):
            let prompt = contextBuilder.buildRecommendationPrompt(
                context: context ?? query,
                userProfile: userProfile.userId.isEmpty ? nil : userProfile,
                conversationHistory: conversationHistory
            )
            return (prompt, PromptMetadata(queryTypeKey: "recommendation", mentionedMediaIds: [], mentionedGenres: []))

        case .moodBased(let mood):
            let prompt = contextBuilder.buildMoodPrompt(mood: mood, userProfile: userProfile.userId.isEmpty ? nil : userProfile)
            return (prompt, PromptMetadata(queryTypeKey: "mood_based", mentionedMediaIds: [], mentionedGenres: [mood.rawValue]))

        case .availability(let title, _):
            let region = await MainActor.run { LocalizationManager.shared.currentLanguageAndRegion().1 }
            let availability = try? await fetchAvailabilitySummary(title: title, region: region)
            return (
                """
                Help the user find where to watch: "\(title)" (region: \(region))

                Known provider info (may be incomplete): \(availability ?? "N/A")

                Provide a helpful answer and suggest what to check if it's not available.
                """,
                PromptMetadata(queryTypeKey: "availability", mentionedMediaIds: [], mentionedGenres: [])
            )
        }
    }

    private func fetchMediaDetailsForTitle(_ title: String, mediaTypeHint: MediaType?) async throws -> (MovieDetails?, Int?) {
        switch mediaTypeHint {
        case .tv:
            if let tv = try? await fetchTVShowDetailsForTitle(title) {
                return tv
            }
            return try await fetchMovieDetailsForTitle(title)

        case .movie:
            if let movie = try? await fetchMovieDetailsForTitle(title) {
                return movie
            }
            return try await fetchTVShowDetailsForTitle(title)

        case .none:
            if let movie = try? await fetchMovieDetailsForTitle(title) {
                return movie
            }
            return try await fetchTVShowDetailsForTitle(title)
        }
    }

    private func fetchMovieDetailsForTitle(_ title: String) async throws -> (MovieDetails?, Int?) {
        let results = try await tmdbService.searchMovies(query: title, page: 1)
        guard let first = results.results.first else {
            return (nil, nil)
        }

        let movie = try await tmdbService.getMovieDetails(id: first.id)
        let credits = try? await tmdbService.getMovieCredits(id: first.id)

        let details = MovieDetails(
            id: movie.id,
            title: movie.title,
            overview: movie.overview,
            releaseDate: movie.releaseDate,
            voteAverage: movie.voteAverage,
            voteCount: movie.voteCount,
            runtime: movie.runtime,
            genres: movie.genres?.map { MovieDetails.Genre(id: $0.id, name: $0.name) },
            credits: credits.map { credits in
                MovieDetails.Credits(
                    cast: credits.cast.prefix(10).map { MovieDetails.CastMember(id: $0.id, name: $0.name, character: $0.character) },
                    crew: credits.crew.prefix(10).map { MovieDetails.CrewMember(id: $0.id, name: $0.name, job: $0.job) }
                )
            }
        )

        return (details, movie.id)
    }

    private func fetchTVShowDetailsForTitle(_ title: String) async throws -> (MovieDetails?, Int?) {
        let results = try await tmdbService.searchTVShows(query: title, page: 1)
        guard let first = results.results.first else {
            return (nil, nil)
        }

        let show = try await tmdbService.getTVShowDetails(id: first.id)
        let credits = try? await tmdbService.getTVShowCredits(id: first.id)

        let details = MovieDetails(
            id: show.id,
            title: show.name,
            overview: show.overview,
            releaseDate: show.firstAirDate,
            voteAverage: show.voteAverage,
            voteCount: show.voteCount,
            runtime: nil,
            genres: show.genres?.map { MovieDetails.Genre(id: $0.id, name: $0.name) },
            credits: credits.map { credits in
                MovieDetails.Credits(
                    cast: credits.cast.prefix(10).map { MovieDetails.CastMember(id: $0.id, name: $0.name, character: $0.character) },
                    crew: credits.crew.prefix(10).map { MovieDetails.CrewMember(id: $0.id, name: $0.name, job: $0.job) }
                )
            }
        )

        return (details, show.id)
    }

    private func fetchAvailabilitySummary(title: String, region: String) async throws -> String? {
        let results = try await tmdbService.searchMovies(query: title, page: 1)
        guard let first = results.results.first else {
            return nil
        }

        let providers = try await tmdbService.getMovieWatchProviders(id: first.id)
        let country = providers.results[region]
        let streaming = country?.flatrate?.map { $0.providerName }.prefix(5).joined(separator: ", ")
        let rent = country?.rent?.map { $0.providerName }.prefix(5).joined(separator: ", ")
        let buy = country?.buy?.map { $0.providerName }.prefix(5).joined(separator: ", ")

        var parts: [String] = []
        if let streaming, !streaming.isEmpty { parts.append("Stream: \(streaming)") }
        if let rent, !rent.isEmpty { parts.append("Rent: \(rent)") }
        if let buy, !buy.isEmpty { parts.append("Buy: \(buy)") }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " | ")
    }
}
