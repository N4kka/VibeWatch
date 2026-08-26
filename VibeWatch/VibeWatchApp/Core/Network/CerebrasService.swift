import Foundation

enum CerebrasError: Error {
    case invalidURL
    case noData
    case decodingError
    case serverError(String)
    /// Quota giornaliera raggiunta; se il server ha allegato il conteggio, e' qui.
    case quotaExceeded(serverUsage: AIServerUsage?)
    /// Il servizio a monte è esaurito per tutti (402 `upstream_capacity` da cerebras-proxy).
    ///
    /// Distinto da `quotaExceeded` perché non è la quota di chi sta chiedendo: dirgli "hai
    /// raggiunto il limite, torna domani" sarebbe falso due volte — non ha speso niente, e
    /// domani sarà spento uguale finché non si ricarica l'account.
    case serviceUnavailable
    case unknown
}

// Request Models
struct CerebrasChatRequest: Codable {
    let model: String
    let messages: [CerebrasMessage]
    let maxTokens: Int?
    let temperature: Double?
    let stream: Bool
    /// Quota bucket tag consumed by cerebras-proxy ("chat" or "aux"); stripped before forwarding.
    let feature: String

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case stream
        case feature
    }
}

/// Authoritative usage snapshot returned by cerebras-proxy: nel body della risposta come campo
/// `vw_usage` (canale primario, i gateway non lo filtrano) e negli header X-AI-* (fallback).
struct AIServerUsage: Codable {
    let bucket: String
    let requestsUsed: Int
    let dailyLimit: Int
    let isPro: Bool

    enum CodingKeys: String, CodingKey {
        case bucket
        case requestsUsed = "requests_used"
        case dailyLimit = "daily_limit"
        case isPro = "is_pro"
    }

    init(bucket: String, requestsUsed: Int, dailyLimit: Int, isPro: Bool) {
        self.bucket = bucket
        self.requestsUsed = requestsUsed
        self.dailyLimit = dailyLimit
        self.isPro = isPro
    }

    init?(httpResponse: HTTPURLResponse) {
        guard
            let usedString = httpResponse.value(forHTTPHeaderField: "X-AI-Requests-Used"),
            let limitString = httpResponse.value(forHTTPHeaderField: "X-AI-Daily-Limit"),
            let used = Int(usedString),
            let limit = Int(limitString)
        else { return nil }
        self.requestsUsed = used
        self.dailyLimit = limit
        self.bucket = httpResponse.value(forHTTPHeaderField: "X-AI-Bucket") ?? "chat"
        self.isPro = httpResponse.value(forHTTPHeaderField: "X-AI-Is-Pro") == "true"
    }

    /// Estrae il conteggio dal body di un 429 del proxy ({requestsUsedToday, dailyLimit, ...}).
    init?(quotaErrorBody data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let used = json["requestsUsedToday"] as? Int,
              let limit = json["dailyLimit"] as? Int else { return nil }
        self.requestsUsed = used
        self.dailyLimit = limit
        self.bucket = json["bucket"] as? String ?? "chat"
        self.isPro = json["isPro"] as? Bool ?? false
    }
}

struct CerebrasMessage: Codable {
    let role: String
    let content: String?
    let reasoning: String?

    /// Initialize for request messages (with content)
    init(role: String, content: String) {
        self.role = role
        self.content = content
        self.reasoning = nil
    }

    /// Returns the response text, preferring content over reasoning
    var responseText: String {
        return content ?? reasoning ?? ""
    }
}

// Response Models
struct CerebrasChatResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [CerebrasChoice]
    let usage: CerebrasUsage?
    /// Iniettato da cerebras-proxy: conteggio quota autorevole del server.
    let vwUsage: AIServerUsage?

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case vwUsage = "vw_usage"
    }
}

struct CerebrasChoice: Codable {
    let index: Int
    let message: CerebrasMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

struct CerebrasUsage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// Service for backend AI processing with Cerebras AI (24M tokens/day)
/// Used for batch operations, content enhancement, and heavy lifting
class CerebrasService {
    @MainActor static let shared = CerebrasService()

    private let baseURL: String = {
        let base = Config.supabaseURL
        guard !base.isEmpty else { return "" }
        let host = base.replacingOccurrences(of: ".supabase.co", with: ".functions.supabase.co")
        return "\(host)/cerebras-proxy"
    }()
    // Placeholder: il model effettivo lo decide cerebras-proxy (quota.ts CHATBOT_MODEL),
    // che sovrascrive sempre questo campo.
    private let defaultModel = "gateway-managed"

    private init() {
        Logger.info("[CerebrasService] Initialized (model selection is gateway-owned)")
    }

    // MARK: - Content Enhancement

    /// Enhance movie descriptions with personalized one-liners
    func enhanceMovieDescriptions(
        movies: [Movie],
        userTone: String = "casual",
        userPreferences: UserProfile? = nil
    ) async throws -> [String: String] {
        var descriptions: [String: String] = [:]

        // Process in chunks of 10 to respect token limits
        let chunks = movies.chunked(into: 10)

        for chunk in chunks {
            let prompt = buildBatchDescriptionPrompt(movies: chunk, tone: userTone, preferences: userPreferences)

            do {
                let response = try await generateText(prompt: prompt, maxTokens: 500, temperature: 0.8)

                // Parse JSON response
                if let data = response.data(using: .utf8),
                   let json = try? JSONDecoder().decode([String: String].self, from: data) {
                    descriptions.merge(json) { _, new in new }
                }
            } catch {
                Logger.error("[CerebrasService] Failed to enhance movie descriptions", error: error)
            }
        }

        return descriptions
    }

    /// Generate a compact semantic embedding for a movie (for local similarity scoring).
    /// Returns a JSON-parsed array of `dimensions` floats.
    func generateMovieEmbedding(movie: Movie, dimensions: Int = 64) async throws -> [Double] {
        let prompt = """
        Create a compact semantic embedding vector for this movie.

        Title: \(movie.title)
        Overview: \(movie.overview)
        Genres: \(movie.genreIds?.map(String.init).joined(separator: ", ") ?? "")
        Release: \(movie.releaseDate ?? "")

        Requirements:
        - Output MUST be a JSON array of exactly \(dimensions) numbers (floats).
        - Each number should be between -1.0 and 1.0.
        - Make it deterministic and stable.
        - Only return the JSON array, no other text.
        """

        let response = try await generateText(prompt: prompt, maxTokens: 600, temperature: 0.0)

        guard let data = response.data(using: .utf8),
              let vector = try? JSONDecoder().decode([Double].self, from: data) else {
            throw CerebrasError.decodingError
        }

        if vector.count == dimensions { return vector }
        if vector.count > dimensions { return Array(vector.prefix(dimensions)) }
        return vector + Array(repeating: 0.0, count: max(0, dimensions - vector.count))
    }

    /// Generate metadata for clips
    func generateClipMetadata(clip: Clip, movieContext: Movie) async throws -> ClipMetadata {
        let prompt = """
        Analyze this movie clip and generate metadata.

        Movie: \(movieContext.title)
        Overview: \(movieContext.overview)
        Clip Title: \(clip.title)

        Generate:
        1. A compelling description (max 20 words)
        2. 3-5 mood tags (e.g., "intense", "emotional", "funny")
        3. Best time to watch (morning/afternoon/evening/night)

        Return as JSON:
        {
            "description": "...",
            "moods": ["...", "..."],
            "bestTime": "..."
        }
        """

        let response = try await generateText(prompt: prompt, maxTokens: 200, temperature: 0.7)

        // Parse JSON response
        if let data = response.data(using: .utf8),
           let metadata = try? JSONDecoder().decode(ClipMetadata.self, from: data) {
            return metadata
        }

        throw CerebrasError.decodingError
    }

    /// Expand search query with semantic keywords
    func expandSearchQuery(query: String) async throws -> [String] {
        let prompt = """
        Expand this movie/TV search query into semantic keywords and related terms.

        Query: "\(query)"

        Return 5-10 related keywords or phrases as a JSON array.
        Example: ["original query", "synonym 1", "related genre", "similar theme"]

        Only return the JSON array, no other text.
        """

        let response = try await generateText(prompt: prompt, maxTokens: 100, temperature: 0.5)

        // Parse JSON array
        if let data = response.data(using: .utf8),
           let keywords = try? JSONDecoder().decode([String].self, from: data) {
            return keywords
        }

        throw CerebrasError.decodingError
    }

    // MARK: - Behavior Analysis

    /// Analyze user behavior patterns for insights
    func analyzeUserBehaviorPatterns(interactions: [UserInteraction]) async throws -> BehaviorInsights {
        let interactionSummaries = interactions.prefix(50).map { interaction in
            """
            Source: \(interaction.source.rawValue)
            Engagement: \(interaction.engagementScore)
            Media: \(interaction.mediaId ?? 0)
            """
        }.joined(separator: "\n")

        let prompt = """
        Analyze these user interactions and identify patterns:

        \(interactionSummaries)

        Generate insights as JSON:
        {
            "emergingGenres": ["genre1", "genre2"],
            "timePatterns": {"morning": 0.2, "afternoon": 0.3, "evening": 0.5},
            "contentTypeRatio": 0.7,
            "dominantMoods": ["mood1", "mood2"]
        }
        """

        let response = try await generateText(prompt: prompt, maxTokens: 300, temperature: 0.3)

        if let data = response.data(using: .utf8),
           let insights = try? JSONDecoder().decode(BehaviorInsights.self, from: data) {
            return insights
        }

        throw CerebrasError.decodingError
    }

    // MARK: - Core API Methods

    /// interactive chat for user-facing features
    /// - Parameters:
    ///   - history: Previous messages in the conversation
    ///   - prompt: The new user message
    ///   - systemPrompt: Optional system override
    /// - Returns: Tuple of (response text, token usage, authoritative server-side quota usage)
    func chat(
        history: [AIChatMessage],
        prompt: String,
        systemPrompt: String? = nil
    ) async throws -> (content: String, tokens: Int, serverUsage: AIServerUsage?) {
        
        guard let url = URL(string: baseURL) else {
            throw CerebrasError.invalidURL
        }

        var messages: [CerebrasMessage] = []
        
        // 1. System Prompt
        let systemContent = systemPrompt ?? "You are a helpful assistant for a movie and TV show discovery app called VibeWatch."
        messages.append(CerebrasMessage(role: "system", content: systemContent))
        
        // 2. History
        for msg in history {
            messages.append(CerebrasMessage(role: msg.role == .user ? "user" : "assistant", content: msg.content))
        }
        
        // 3. New Prompt
        messages.append(CerebrasMessage(role: "user", content: prompt))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let session = try await AuthService.shared.client?.auth.session
        guard let accessToken = session?.accessToken, !accessToken.isEmpty else {
            throw CerebrasError.unknown
        }
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = CerebrasChatRequest(
            model: defaultModel,
            messages: messages,
            maxTokens: 1024,
            temperature: 0.7,
            stream: false,
            feature: "chat"
        )

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw CerebrasError.decodingError
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CerebrasError.unknown
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // 402 e 429 vogliono dire due cose opposte e vanno tenute separate: il 402 e il
            // servizio spento per tutti, il 429 e la quota di questo utente.
            if httpResponse.statusCode == 402 {
                throw CerebrasError.serviceUnavailable
            }
            if httpResponse.statusCode == 429 {
                // Il body del 429 del proxy contiene il conteggio autorevole: lo si propaga
                // cosi il badge si riallinea anche quando il limite scatta lato server.
                throw CerebrasError.quotaExceeded(serverUsage: AIServerUsage(quotaErrorBody: data))
            }
            if let errorString = String(data: data, encoding: .utf8) {
                throw CerebrasError.serverError(errorString)
            }
            throw CerebrasError.serverError("Status code: \(httpResponse.statusCode)")
        }

        do {
            let decodedResponse = try JSONDecoder().decode(CerebrasChatResponse.self, from: data)
            var content = decodedResponse.choices.first?.message.responseText ?? ""

            // Clean content: remove <think>...</think> or similar reasoning tags if present
            content = cleanAIResponse(content)

            let tokens = decodedResponse.usage?.totalTokens ?? 0
            // Usage: prima il body (vw_usage, immune ai gateway che filtrano header), poi header.
            let serverUsage = decodedResponse.vwUsage ?? AIServerUsage(httpResponse: httpResponse)

            Logger.debug("[CerebrasService] Chat generated \(tokens) tokens (serverUsage: \(serverUsage.map { "\($0.requestsUsed)/\($0.dailyLimit)" } ?? "assente"))")
            return (content, tokens, serverUsage)
        } catch {
            Logger.error("[CerebrasService] Decoding Error: \(error.localizedDescription)")
            throw CerebrasError.decodingError
        }
    }

    // MARK: - New Personalization Features

    /// Rewrite loglines for multiple movies to appeal to a specific user
    func rewriteLoglines(
        movies: [MovieDetails],
        userProfile: UserProfile
    ) async throws -> [Int: String] {
        var rewrites: [Int: String] = [:]
        
        // Process in chunks (e.g. 5 at a time) to avoid massive prompts, or individually for higher quality.
        // For "Dynamic Living Loglines", individual high-quality rewrites might be better if budget allows,
        // but batching is more efficient. Let's try individual for now as per strategy (Top 40 items).
        // Actually, individual calls in parallel might hit rate limits.
        // Let's stick to individual calls for the high-value "Daily Mix" and potential batching later.
        // For this implementation, we will provide a method that handles ONE movie, and the caller can loop/group.
        // Wait, the requirement was "rewriteLoglines(movies...)" suggesting batch.
        
        // Let's do a simple loop for now (caller handles concurrency).
        for movie in movies {
            let prompt = AIContextBuilder.shared.buildLoglineRewritePrompt(movie: movie, userProfile: userProfile)
            do {
                let rewritten = try await generateText(prompt: prompt, maxTokens: 60, temperature: 0.7)
                rewrites[movie.id] = rewritten
            } catch {
                Logger.warning("[CerebrasService] Failed to rewrite logline for \(movie.id)")
            }
        }
        
        return rewrites
    }

    /// Analyze immediate session vibe based on recent interactions
    func analyzeSessionVibe(
        recentInteractions: [String]
    ) async throws -> [String: Double] {
        let prompt = AIContextBuilder.shared.buildMicroAnalysisPrompt(recentInteractions: recentInteractions)
        
        let response = try await generateText(prompt: prompt, maxTokens: 200, temperature: 0.5)
        
        // Expected JSON: {"boost_genres": [], "suppress_genres": []}
        // We want to return a weight map: Boost = +0.2, Suppress = -0.2
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        
        var adjustments: [String: Double] = [:]
        
        if let boosts = json["boost_genres"] as? [String] {
            for genre in boosts { adjustments[genre] = 0.2 }
        }
        
        if let suppresses = json["suppress_genres"] as? [String] {
            for genre in suppresses { adjustments[genre] = -0.2 }
        }
        
        return adjustments
    }

    /// Generate "Why For Me?" explanation
    func generateWhyForMe(
        movie: MovieDetails,
        userProfile: UserProfile,
        languageName: String? = nil,
        languageCode: String? = nil
    ) async throws -> WhyForMeAnalysis {
        var prompt = AIContextBuilder.shared.buildWhyForMePrompt(movie: movie, userProfile: userProfile)
        if let languageName, !languageName.isEmpty {
            prompt += "\n\nLANGUAGE: Respond only in \(languageName). Do not include any English."
        }
        if let languageCode, !languageCode.isEmpty {
            prompt += "\nLANGUAGE_CODE: \(languageCode). Use only this language."
        }
        prompt += """

        OUTPUT FORMAT:
        {"mood":"...","genres":"...","cast":"..."}
        Only return valid JSON.
        """
        let systemPrompt: String?
        if let languageName, !languageName.isEmpty {
            systemPrompt = "You are a helpful assistant for a movie and TV show discovery app called VibeWatch. Respond only in \(languageName)."
        } else {
            systemPrompt = nil
        }
        let raw = try await generateText(prompt: prompt, systemPrompt: systemPrompt, maxTokens: 260, temperature: 0.7)
        if let jsonString = extractJsonObject(from: raw),
           let data = jsonString.data(using: .utf8),
           let response = try? JSONDecoder().decode(WhyForMeAnalysis.self, from: data),
           response.isCompleteAndDistinct {
            return response
        }
        throw CerebrasError.decodingError
    }

    /// Generate Smart Nudge notification text
    func generateSmartNudge(
        userProfile: UserProfile,
        candidates: [String]
    ) async throws -> String {
        let prompt = AIContextBuilder.shared.buildSmartNudgePrompt(userProfile: userProfile, candidates: candidates)
        return try await generateText(prompt: prompt, maxTokens: 60, temperature: 0.7)
    }

    /// Removes reasoning tags like <think>...</think> from the response string.
    private func cleanAIResponse(_ text: String) -> String {
        var cleaned = text
        // Remove <think>...</think> blocks
        let pattern = "<think>[\\s\\S]*?</think>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractJsonObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start...end])
    }

    private func sanitizeWhyForMeFallback(_ text: String) -> String {
        let cleaned = cleanAIResponse(text)
        let lines = cleaned
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let filteredLines = lines.filter { line in
            let lower = line.lowercased()
            if lower.hasPrefix("*") || lower.hasPrefix("-") { return false }
            if lower.range(of: #"^\d+\."#, options: .regularExpression) != nil { return false }
            if lower.contains("constraint") || lower.contains("analysis") || lower.contains("draft") { return false }
            if lower.contains("analyze") || lower.contains("overview") { return false }
            if lower.contains("top genres") || lower.contains("genres:") { return false }
            if lower.contains("cast:") || lower.contains("input") { return false }
            if line.contains("**") { return false }
            return true
        }

        let collapsed = filteredLines.joined(separator: " ")
        let sentences = collapsed.split(whereSeparator: { ".!?".contains($0) })
        let trimmedSentences = sentences.prefix(2).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let result = trimmedSentences.joined(separator: ". ")
        return result.isEmpty ? cleaned : result + (result.hasSuffix(".") ? "" : ".")
    }

    /// Sends a chat prompt to the Cerebras API
    /// - Parameters:
    ///   - prompt: The user's input string
    ///   - systemPrompt: Optional system instruction to guide the AI's behavior
    ///   - model: The model to use (defaults to llama3.1-8b)
    /// - Returns: The AI's string response
    func generateResponse(
        prompt: String,
        systemPrompt: String = "You are a helpful assistant for a movie and TV show discovery app called VibeWatch.",
        model: String? = nil
    ) async throws -> CerebrasChatResponse {

        guard let url = URL(string: baseURL) else {
            throw CerebrasError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let session = try await AuthService.shared.client?.auth.session
        guard let accessToken = session?.accessToken, !accessToken.isEmpty else {
            throw CerebrasError.unknown
        }
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = [
            CerebrasMessage(role: "system", content: systemPrompt),
            CerebrasMessage(role: "user", content: prompt)
        ]

        let requestBody = CerebrasChatRequest(
            model: model ?? defaultModel,
            messages: messages,
            maxTokens: 1024,
            temperature: 0.7,
            stream: false,
            feature: "aux"
        )

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw CerebrasError.decodingError
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CerebrasError.unknown
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 402 {
                throw CerebrasError.serviceUnavailable
            }
            if httpResponse.statusCode == 429 {
                throw CerebrasError.quotaExceeded(serverUsage: AIServerUsage(quotaErrorBody: data))
            }
            if let errorString = String(data: data, encoding: .utf8) {
                throw CerebrasError.serverError(errorString)
            }
            throw CerebrasError.serverError("Status code: \(httpResponse.statusCode)")
        }

        do {
            let decodedResponse = try JSONDecoder().decode(CerebrasChatResponse.self, from: data)
            Logger.debug("[CerebrasService] Generated \(decodedResponse.usage?.totalTokens ?? 0) tokens")
            return decodedResponse
        } catch {
            // Print raw response for debugging
            if let rawResponse = String(data: data, encoding: .utf8) {
                Logger.error("[CerebrasService] Raw API Response: \(rawResponse)")
            }
            Logger.error("[CerebrasService] Decoding Error: \(error.localizedDescription)")
            throw CerebrasError.decodingError
        }
    }

    /// Generate text with specific parameters
    func generateText(
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 1024,
        temperature: Double = 0.7
    ) async throws -> String {
        let system = systemPrompt ?? "You are a helpful assistant for a movie and TV show discovery app called VibeWatch."
        let response = try await generateResponse(prompt: prompt, systemPrompt: system, model: nil)
        let content = response.choices.first?.message.responseText ?? ""
        return cleanAIResponse(content)
    }

    // MARK: - Private Helper Methods

    private func buildBatchDescriptionPrompt(
        movies: [Movie],
        tone: String,
        preferences: UserProfile?
    ) -> String {
        let movieList = movies.map { movie in
            """
            {
                "id": \(movie.id),
                "title": "\(movie.title)",
                "genres": "\(movie.genreIds?.map { String($0) }.joined(separator: ", ") ?? "")",
                "overview": "\(movie.overview)"
            }
            """
        }.joined(separator: ",\n")

        var prompt = """
        Generate engaging one-liner descriptions (max 15 words each) for these movies in a \(tone) tone.

        Movies:
        [\(movieList)]
        """

        if let prefs = preferences {
            let topGenres = prefs.topGenres.prefix(3).map { $0.genreName }.joined(separator: ", ")
            prompt += "\n\nUser prefers: \(topGenres)"
        }

        prompt += """

        Return as JSON: {"movieId": "description"}
        Only return the JSON object, no other text.
        """

        return prompt
    }
}

// MARK: - Supporting Models

struct ClipMetadata: Codable {
    let description: String
    let moods: [String]
    let bestTime: String

    enum CodingKeys: String, CodingKey {
        case description, moods
        case bestTime = "bestTime"
    }
}

struct BehaviorInsights: Codable {
    let emergingGenres: [String]
    let timePatterns: [String: Double]
    let contentTypeRatio: Double
    let dominantMoods: [String]

    enum CodingKeys: String, CodingKey {
        case emergingGenres, timePatterns, contentTypeRatio, dominantMoods
    }
}
