import Foundation
import SwiftUI
import UIKit

@MainActor
class AIRecommendationViewModel: ObservableObject {
    @Published var prompt: String = ""
    @Published var messages: [AIMessage] = []
    @Published var isLoading: Bool = false
    @Published var error: String?
    /// Chip filtro attive: diventano vincoli nel system prompt.
    @Published var activeFilters: [AIChatFilter] = []

    /// Chip disponibili: le piattaforme scelte dall'utente (se presenti) + i filtri fissi.
    var availableFilters: [AIChatFilter] {
        var filters: [AIChatFilter] = []
        let names = ProviderSelectionCodec.decodeNames(
            UserDefaults.standard.data(forKey: "selectedProviderNames") ?? Data()
        )
        if !names.isEmpty {
            filters.append(.myPlatforms(names.sorted()))
        }
        filters.append(contentsOf: [.recent, .shorter, .hiddenGems])
        return filters
    }

    func toggleFilter(_ filter: AIChatFilter) {
        if let index = activeFilters.firstIndex(of: filter) {
            activeFilters.remove(at: index)
        } else {
            activeFilters.append(filter)
        }
    }
    
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
    private var localDataResetObserver: NSObjectProtocol?
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

        // Il pannello AI vive quanto l'app: senza questo, la conversazione dell'account precedente
        // resterebbe leggibile — e riutilizzata come contesto — dopo un cambio utente.
        localDataResetObserver = NotificationCenter.default.addObserver(
            forName: .localUserDataDidReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.messages = []
                self.prompt = ""
                self.activeFilters = []
                self.error = nil
                await self.conversationMemory.resetSession()
            }
        }
    }

    deinit {
        if let timeChangeObserver {
            NotificationCenter.default.removeObserver(timeChangeObserver)
        }
        if let localDataResetObserver {
            NotificationCenter.default.removeObserver(localDataResetObserver)
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
            AnalyticsService.shared.track(.aiChatMessageSent(
                queryType: classification.type.analyticsName,
                conversationLength: messages.count))
            let profile = await preferenceManager.aggregatePreferences()

            let seenTitles = seenTitlesForPrompt()
            let savedEntries = savedEntriesForPrompt(seenTitles: seenTitles)

            // Persona, formato e contratto vibe-json stanno nel gateway, identici a ogni
            // richiesta: qui si manda solo cio' che cambia (profilo, esclusi, titolo, lingua),
            // attaccato al turno utente perche' il caching aggancia per prefisso.
            let (prompt, metadata) = try await buildPromptAndMetadata(
                query: query,
                classification: classification,
                userProfile: profile,
                seenTitles: seenTitles,
                savedEntries: savedEntries,
                languageName: englishLanguageName(for: query)
            )

            let history = conversationHistoryForModel()
            let (content, tokens, serverUsage) = try await cerebrasService.chat(
                history: history,
                prompt: prompt
            )

            // Contratto ibrido: testo conversazionale + eventuale blocco vibe-json di titoli,
            // risolti via TMDB in card. Se il parse fallisce si degrada a bolla di solo testo.
            let parsed = AIResponseParser.parse(content)
            let cards = await resolveCards(parsed.recommendations, excluding: seenTitles, saved: savedEntries)

            let aiMessage = AIMessage(
                content: content,
                isUser: false,
                text: parsed.text,
                cards: cards
            )
            messages.append(aiMessage)

            // Record Usage: il proxy ritorna il conteggio autorevole negli header; il +1 locale
            // resta solo come fallback per risposte senza header.
            if let serverUsage {
                aiTokenManager.applyServerUsage(used: serverUsage.requestsUsed, limit: serverUsage.dailyLimit)
            } else {
                aiTokenManager.recordUsage()
            }
            await syncWithTokenManager()

            // Si persiste il content RAW (blocco incluso): la re-hydration ri-parsa in card e il
            // modello rivede il proprio contratto nella history dei turni successivi.
            let resolvedIds = cards.map { $0.tmdbId }
            await conversationMemory.append(
                role: .assistant,
                content: content,
                queryType: metadata.queryTypeKey,
                mentionedMediaIds: resolvedIds.isEmpty ? metadata.mentionedMediaIds : resolvedIds,
                mentionedGenres: metadata.mentionedGenres,
                tokensUsed: tokens
            )

        } catch CerebrasError.quotaExceeded(let serverUsage) {
            // Il 429 del proxy porta il conteggio autorevole: il badge si riallinea subito
            // invece di restare indietro rispetto al server.
            if let serverUsage {
                aiTokenManager.applyServerUsage(used: serverUsage.requestsUsed, limit: serverUsage.dailyLimit)
                await syncWithTokenManager()
            }
            self.error = "ai.hardLimitMessage".localized

        } catch CerebrasError.serviceUnavailable {
            // Il servizio a monte e' spento per tutti: non e' un limite dell'utente e non si
            // sblocca a mezzanotte, quindi non deve leggere "torna domani".
            Logger.error("[AIRecommendationViewModel] AI upstream esaurito (402 upstream_capacity)")
            self.error = "ai.serviceUnavailable".localized

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

    /// "Altri": chiede altri titoli sulla stessa linea, passando dal normale flusso (1 richiesta).
    func requestMore() async {
        prompt = "ai.moreLikeThese".localized
        await sendMessage()
    }

    /// Titolo della chat corrente per il sottotitolo dell'header: il titolo custom (rinomina)
    /// se presente, altrimenti il primo messaggio utente troncato a confine di parola.
    var chatTitle: String? {
        if let custom = conversationMemory.customTitle(for: conversationMemory.sessionId) {
            return custom
        }
        guard let first = messages.first(where: { $0.isUser })?.content else { return nil }
        return Self.chatTitle(from: first)
    }

    static func chatTitle(from firstUserMessage: String, maxLength: Int = 40) -> String {
        let collapsed = firstUserMessage
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        let cut = collapsed.prefix(maxLength)
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return trimmed + "…"
    }

    /// Nuova chat: azzera la sessione della memoria conversazionale e la UI.
    func startNewChat() async {
        await conversationMemory.resetSession()
        messages = []
        prompt = ""
        error = nil
    }

    // MARK: - Multi-chat

    @Published var sessions: [AIChatSessionSummary] = []

    func loadSessions() async {
        sessions = await conversationMemory.listSessions()
    }

    /// Riapre una chat dalla cronologia.
    func selectSession(_ sessionId: String) async {
        await conversationMemory.switchSession(to: sessionId)
        hydrateMessagesFromMemory()
        error = nil
    }

    /// Fissa/sblocca una chat in cima alla cronologia.
    func togglePin(_ sessionId: String) async {
        conversationMemory.setPinned(sessionId, pinned: !conversationMemory.isPinned(sessionId))
        await loadSessions()
    }

    /// Rinomina una chat (stringa vuota = torna al titolo automatico).
    func renameSession(_ sessionId: String, title: String) async {
        conversationMemory.renameSession(sessionId, title: title)
        await loadSessions()
        objectWillChange.send() // il sottotitolo dell'header legge chatTitle
    }

    /// Elimina una chat dalla cronologia (e, se era quella aperta, riparte pulita).
    func deleteSession(_ sessionId: String) async {
        let wasCurrent = sessionId == conversationMemory.sessionId
        await conversationMemory.deleteSession(sessionId)
        sessions.removeAll { $0.sessionId == sessionId }
        if wasCurrent {
            messages = []
            prompt = ""
            error = nil
        }
    }

    /// Quanti dei titoli proposti in una sessione sono ora in watchlist (meta "2 in watchlist").
    func watchlistCount(for summary: AIChatSessionSummary) -> Int {
        let listManager = ListManager.shared
        let watchlistIds = Set(listManager.watchlist.items.map { $0.mediaId })
        return summary.proposedMediaIds.filter { watchlistIds.contains($0) }.count
    }

    // MARK: - Card actions

    func isCardInWatchlist(_ card: AIRecommendationCardModel) -> Bool {
        let listManager = ListManager.shared
        return listManager.isInList(listId: listManager.watchlist.id, mediaId: card.tmdbId, mediaType: card.mediaType)
    }

    /// "+ Aggiungi": salva il titolo della card in watchlist.
    func addCardToWatchlist(_ card: AIRecommendationCardModel) async {
        let listManager = ListManager.shared
        do {
            try await listManager.addToList(
                listId: listManager.watchlist.id,
                movie: card.asMovie(),
                mediaType: card.mediaType
            )
        } catch {
            Logger.warning("[AIRecommendationViewModel] addCardToWatchlist failed: \(error)")
        }
    }

    /// Feedback pollice su/giù sull'ultima risposta (v1: stato locale + log).
    func recordFeedback(for messageId: UUID, positive: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[index].feedback = positive
        Logger.info("[AIRecommendationViewModel] Feedback \(positive ? "up" : "down") on message \(messageId)")
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
            .map { message -> AIMessage in
                guard message.role != .user else {
                    return AIMessage(content: message.content, isUser: true)
                }
                // I messaggi assistant sono persistiti raw: si ri-parsa il blocco vibe-json e si
                // risolvono le card in un secondo momento (fuori dal path sincrono di apertura).
                let parsed = AIResponseParser.parse(message.content)
                return AIMessage(content: message.content, isUser: false, text: parsed.text, cards: [])
            }
        Task { await rehydrateCards() }
    }

    /// Risolve le card dei messaggi idratati dalla history (le raccomandazioni sono nel content
    /// raw). Aggiorna i messaggi al loro posto man mano che le card arrivano.
    private func rehydrateCards() async {
        for index in messages.indices where !messages[index].isUser {
            let parsed = AIResponseParser.parse(messages[index].content)
            guard !parsed.recommendations.isEmpty else { continue }
            let cards = await resolveCards(parsed.recommendations)
            guard index < messages.count else { break }
            messages[index].cards = cards
        }
    }

    /// Solo i visti: il vincolo duro "non riproporre". La watchlist stava qui dentro e non ci
    /// doveva stare — vedi `savedEntriesForPrompt`.
    private func seenTitlesForPrompt() -> [String] {
        var unique: [String] = []
        var known = Set<String>()
        for title in ListManager.shared.seenList.items.map(\.title) {
            let key = title.lowercased()
            if known.insert(key).inserted { unique.append(title) }
        }
        return unique
    }

    /// Cio' che l'utente si e' scelto da solo e non ha ancora visto: watchlist + liste custom.
    /// Non e' un'esclusione ma un bacino da cui pescare, quindi porta anche la durata (che sta
    /// gia' in locale, `MediaListItem.runtime`) e il nome della lista di provenienza.
    /// Ordine per data di aggiunta decrescente: se il cap taglia, taglia le cose piu' vecchie.
    private func savedEntriesForPrompt(seenTitles: [String]) -> [AIContextBuilder.SavedEntry] {
        let listManager = ListManager.shared
        let seen = Set(seenTitles.map { $0.lowercased() })

        let sources: [(list: MediaList, tag: String?)] = [(listManager.watchlist, nil)]
            + listManager.lists.filter { $0.type == .custom }.map { ($0, $0.name) }

        var entries: [(entry: AIContextBuilder.SavedEntry, addedAt: Date)] = []
        var known = Set<String>()

        for source in sources {
            for item in source.list.items {
                let key = item.title.lowercased()
                // Un titolo gia' visto non e' piu' "da vedere", anche se la riga di lista e'
                // rimasta li: proporglielo come novita' sarebbe il bug di prima al contrario.
                guard !seen.contains(key), known.insert(key).inserted else { continue }
                entries.append((
                    AIContextBuilder.SavedEntry(
                        tmdbId: item.mediaId,
                        mediaType: item.mediaType,
                        title: item.title,
                        year: item.releaseDate.flatMap { Int($0.prefix(4)) },
                        runtime: item.mediaType == .movie ? item.runtime : nil,
                        listName: source.tag
                    ),
                    item.addedAt
                ))
            }
        }

        return entries.sorted { $0.addedAt > $1.addedAt }.map(\.entry)
    }

    // MARK: - Card resolution

    /// Risolve le raccomandazioni del modello in card via ricerca TMDB. Match sull'anno ±1 quando
    /// disponibile, altrimenti primo risultato; i titoli irrisolvibili vengono scartati in
    /// silenzio (guardia anti-allucinazione: mai una card col poster sbagliato).
    /// - Parameter excludedTitles: il vincolo duro "mai riproporre cio' che ha gia' visto".
    ///   Al prompt ne va solo un assaggio (12 titoli): la lista intera la applica il codice, qui,
    ///   dove costa un Set e il modello non puo' discutere. **Solo i visti**: filtrare anche la
    ///   watchlist cancellava le card giuste quando l'utente chiedeva un consiglio proprio da li.
    ///   Vuota in re-hydration, altrimenti una card sparirebbe da una chat vecchia solo perche'
    ///   nel frattempo quel titolo e' finito tra i visti.
    /// - Parameter saved: le liste dell'utente. Un titolo che compare qui non si cerca per nome:
    ///   l'id ce l'abbiamo gia', ed e' l'unico modo per avere la certezza che la card sia
    ///   proprio quel film e non un omonimo.
    private func resolveCards(
        _ recommendations: [AIParsedRecommendation],
        excluding seenTitles: [String] = [],
        saved: [AIContextBuilder.SavedEntry] = []
    ) async -> [AIRecommendationCardModel] {
        guard !recommendations.isEmpty else { return [] }

        let excluded = Set(seenTitles.map { $0.lowercased() })
        let allowed = recommendations.filter { !excluded.contains($0.title.lowercased()) }
        guard !allowed.isEmpty else { return [] }

        let knownByTitle = Dictionary(saved.map { ($0.title.lowercased(), $0) }) { first, _ in first }

        var resolved: [(Int, AIRecommendationCardModel)] = []
        await withTaskGroup(of: (Int, AIRecommendationCardModel?).self) { group in
            for (index, rec) in allowed.prefix(5).enumerated() {
                group.addTask { [weak self] in
                    (index, await self?.resolveCard(rec, known: knownByTitle[rec.title.lowercased()]))
                }
            }
            for await (index, card) in group {
                if let card { resolved.append((index, card)) }
            }
        }
        return resolved.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    private func resolveCard(
        _ rec: AIParsedRecommendation,
        known: AIContextBuilder.SavedEntry?
    ) async -> AIRecommendationCardModel? {
        // Il tipo lo decide la lista quando il titolo viene da li: e' un dato, non una previsione.
        switch known?.mediaType ?? rec.mediaType {
        case .movie:
            let id: Int
            if let known {
                id = known.tmdbId
            } else {
                guard let results = try? await tmdbService.searchMovies(query: rec.title, page: 1).results,
                      let match = Self.pickBestMatch(results, year: rec.year, yearOf: { $0.year }, votesOf: { $0.voteCount })
                else { return nil }
                id = match.id
            }
            guard let details = try? await tmdbService.getMovieDetails(id: id) else { return nil }

            return AIRecommendationCardModel(
                tmdbId: details.id,
                mediaType: .movie,
                title: details.title,
                year: details.year,
                posterPath: details.posterPath,
                matchPercent: rec.confidence,
                reason: rec.reason,
                seasonsOrRuntime: details.formattedRuntime,
                country: localizedCountry(details.productionCountries)
            )

        case .tv:
            let id: Int
            if let known {
                id = known.tmdbId
            } else {
                guard let results = try? await tmdbService.searchTVShows(query: rec.title, page: 1).results,
                      let match = Self.pickBestMatch(results, year: rec.year, yearOf: { $0.year }, votesOf: { $0.voteCount })
                else { return nil }
                id = match.id
            }
            guard let details = try? await tmdbService.getTVShowDetails(id: id) else { return nil }

            let seasons = details.numberOfSeasons.map { count in
                count == 1
                    ? "ai.card.oneSeason".localized
                    : String(format: "ai.card.seasonCount".localized, count)
            }
            return AIRecommendationCardModel(
                tmdbId: details.id,
                mediaType: .tv,
                title: details.name,
                year: details.year,
                posterPath: details.posterPath,
                matchPercent: rec.confidence,
                reason: rec.reason,
                seasonsOrRuntime: seasons,
                country: localizedCountry(details.productionCountries)
            )
        }
    }

    /// Fra i risultati con anno compatibile vince quello con piu' voti, non il primo che capita.
    /// Su un titolo ambiguo il primo compatibile puo' essere un omonimo qualunque: "The Hunt"
    /// (2013) agganciava un cortometraggio da 8 minuti, e la card che ne usciva sembrava vera.
    static func pickBestMatch<T>(
        _ results: [T],
        year: Int?,
        yearOf: (T) -> String?,
        votesOf: (T) -> Int
    ) -> T? {
        guard let year else { return results.first }
        let compatible = results.filter { item in
            guard let itemYear = yearOf(item).flatMap({ Int($0) }) else { return false }
            return abs(itemYear - year) <= 1
        }
        return compatible.max { votesOf($0) < votesOf($1) } ?? results.first
    }

    private func localizedCountry(_ countries: [ProductionCountry]?) -> String? {
        guard let iso = countries?.first?.iso else { return nil }
        return Locale.current.localizedString(forRegionCode: iso)
    }

    private func conversationHistoryForModel() -> [AIChatMessage] {
        let historical = conversationMemory.recentMessages()

        // We already pass the current prompt separately to Chutes; avoid duplicating if the last message is a user prompt.
        if let last = historical.last, last.role == .user {
            return Array(historical.dropLast())
        }
        return historical
    }

    /// Il marker `[reply in]` del turno utente. Con un reasoning effort basso il modello non
    /// cambia lingua da solo — 0 volte su 10 senza il marker, 5 su 5 con. Il nome della lingua e'
    /// in inglese perche' finisce dentro un prompt in inglese: con `Locale.current` la riga
    /// diventava "[reply in] italiano".
    ///
    /// NB: la cronologia NON si filtra piu' per lingua. Lo faceva, e cambiare lingua a meta'
    /// conversazione cancellava tutto il contesto precedente.
    private func englishLanguageName(for query: String) -> String? {
        guard let code = languageDetector.detectLanguage(for: query) else { return nil }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code)
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

    /// Il turno utente: la query grezza preceduta dal solo contesto volatile. Nessun template di
    /// task per tipo di query — imponevano formati in conflitto col contratto del gateway (era il
    /// motivo per cui "e' uscito nel 2026?" tornava in tre paragrafi invece che in una riga).
    private func buildPromptAndMetadata(
        query: String,
        classification: QueryClassification,
        userProfile: UserProfile,
        seenTitles: [String],
        savedEntries: [AIContextBuilder.SavedEntry],
        languageName: String?
    ) async throws -> (String, PromptMetadata) {
        let profile = userProfile.userId.isEmpty ? nil : userProfile

        func turn(media: (MovieDetails, MediaType)? = nil, availability: String? = nil) -> String {
            contextBuilder.buildUserTurn(
                query: query,
                userProfile: profile,
                seenTitles: seenTitles,
                savedEntries: savedEntries,
                activeFilters: activeFilters,
                media: media,
                availability: availability,
                languageName: languageName
            )
        }

        switch classification.type {
        case .specificMedia(let title, let mediaTypeHint):
            let (details, kind, mediaId) = try await fetchMediaDetailsForTitle(title, mediaTypeHint: mediaTypeHint)
            return (
                turn(media: details.map { ($0, kind) }),
                PromptMetadata(queryTypeKey: "specific_media", mentionedMediaIds: mediaId.map { [$0] } ?? [], mentionedGenres: [])
            )

        case .informational:
            return (turn(), PromptMetadata(queryTypeKey: "informational", mentionedMediaIds: [], mentionedGenres: []))

        case .comparison:
            return (turn(), PromptMetadata(queryTypeKey: "comparison", mentionedMediaIds: [], mentionedGenres: []))

        case .recommendation:
            return (turn(), PromptMetadata(queryTypeKey: "recommendation", mentionedMediaIds: [], mentionedGenres: []))

        case .moodBased(let mood):
            return (turn(), PromptMetadata(queryTypeKey: "mood_based", mentionedMediaIds: [], mentionedGenres: [mood.rawValue]))

        case .availability(let title, _):
            let region = await MainActor.run { LocalizationManager.shared.currentLanguageAndRegion().1 }
            let availability = try? await fetchAvailabilitySummary(title: title, region: region)
            return (
                turn(availability: availability.map { "\(title) (\(region)): \($0)" }),
                PromptMetadata(queryTypeKey: "availability", mentionedMediaIds: [], mentionedGenres: [])
            )
        }
    }

    /// Restituisce anche il tipo risolto, non solo l'hint: la riga `[title]` del turno utente
    /// dice al modello "movie" o "tv", ed e' quello che poi finisce nel campo type della card.
    private func fetchMediaDetailsForTitle(
        _ title: String,
        mediaTypeHint: MediaType?
    ) async throws -> (MovieDetails?, MediaType, Int?) {
        if mediaTypeHint == .tv {
            if let tv = try? await fetchTVShowDetailsForTitle(title) {
                return (tv.0, .tv, tv.1)
            }
            let movie = try await fetchMovieDetailsForTitle(title)
            return (movie.0, .movie, movie.1)
        }

        // Senza hint si prova prima film: e' il caso piu' frequente, e il fallback copre l'altro.
        if let movie = try? await fetchMovieDetailsForTitle(title) {
            return (movie.0, .movie, movie.1)
        }
        let tv = try await fetchTVShowDetailsForTitle(title)
        return (tv.0, .tv, tv.1)
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
