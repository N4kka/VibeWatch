import Foundation

/// Service for building AI context and system prompts
/// Generates personalized prompts based on user profile and query type
class AIContextBuilder {
    static let shared = AIContextBuilder()

    // MARK: - Initialization

    private init() {
        Logger.info("[AIContextBuilder] Initialized")
    }

    // MARK: - Public Methods

    /// Build system prompt for AI based on user profile and query type
    func buildSystemPrompt(
        userProfile: UserProfile?,
        queryType: QueryType
    ) -> String {
        var prompt = baseSystemPrompt()

        if let profile = userProfile {
            prompt += "\n\n" + buildUserProfileSection(profile)
        }

        prompt += "\n\n" + buildTaskSection(queryType: queryType)

        return prompt
    }

    /// Build user context for AI prompt
    func buildUserContext(userProfile: UserProfile) -> String {
        var context = "USER CONTEXT:\n"

        // Top Genres
        if !userProfile.topGenres.isEmpty {
            let genres = userProfile.topGenres.prefix(5).map { $0.genreName }.joined(separator: ", ")
            context += "- Favorite Genres: \(genres)\n"
        }

        // Recently Watched
        if !userProfile.recentActivity.watchedMedia.isEmpty {
            let watched = userProfile.recentActivity.watchedMedia
                .prefix(5)
                .map { "\($0.title)\($0.year.map { " (\($0))" } ?? "")" }
                .joined(separator: ", ")
            context += "- Recently Watched: \(watched)\n"
        }

        // Liked Media
        if !userProfile.recentActivity.likedMedia.isEmpty {
            let liked = userProfile.recentActivity.likedMedia
                .prefix(3)
                .map { $0.title }
                .joined(separator: ", ")
            context += "- Liked Movies/Shows: \(liked)\n"
        }

        // Top Actors
        if !userProfile.topActors.isEmpty {
            let actors = userProfile.topActors.prefix(5).map { $0.name }.joined(separator: ", ")
            context += "- Favorite Actors: \(actors)\n"
        }

        // Watch Patterns
        if let preferredTime = userProfile.watchPatterns.preferredTimeOfDay {
            context += "- Watch Time Preference: \(preferredTime)\n"
        }

        // Content Type Preference
        let moviePercentage = Int(userProfile.contentTypePreference.movieRatio * 100)
        let tvPercentage = Int(userProfile.contentTypePreference.tvRatio * 100)
        context += "- Content Preference: Movies \(moviePercentage)% | TV Shows \(tvPercentage)%\n"

        // Moods
        if !userProfile.preferredMoods.isEmpty {
            let moods = userProfile.preferredMoods.map { $0.displayName }.joined(separator: ", ")
            context += "- Preferred Moods: \(moods)\n"
        }

        return context
    }

    /// Build enhanced prompt for specific media query
    func buildSpecificMediaPrompt(
        title: String,
        movieDetails: MovieDetails? = nil,
        userProfile: UserProfile?,
        userReaction: String? = nil,
        hasWatched: Bool = false
    ) -> String {
        var prompt = """
        The user is asking about ONE specific title: \(title).
        Answer the question about this title directly. Do NOT add extra recommendations unless the user asked for them.
        """

        if let details = movieDetails {
            prompt += """

            MEDIA DATA:
            - Title: \(details.title) (\(details.releaseDate?.prefix(4) ?? "N/A"))
            - Genres: \(details.genres?.map { $0.name }.joined(separator: ", ") ?? "N/A")
            - Rating: \(String(format: "%.1f", details.voteAverage))/10 (\(details.voteCount) votes)
            - Overview: \(details.overview ?? "No overview available")
            """
            if let runtime = details.runtime, runtime > 0 {
                prompt += "\n- Runtime: \(runtime) minutes"
            }

            if let cast = details.credits?.cast?.prefix(5) {
                let castNames = cast.map { $0.name }.joined(separator: ", ")
                prompt += "\n- Cast: \(castNames)"
            }

            if let director = details.credits?.crew?.first(where: { $0.job == "Director" }) {
                prompt += "\n- Director: \(director.name)"
            }
        }

        if let profile = userProfile {
            let topGenres = profile.topGenres.prefix(3).map { $0.genreName }.joined(separator: ", ")
            prompt += """

            USER CONTEXT:
            - User's Favorite Genres: \(topGenres)
            """
        }

        if let reaction = userReaction {
            prompt += "\n- User's Previous Reaction: \(reaction)"
        }

        if hasWatched {
            prompt += "\n- User Has Already Watched This"
        }

        prompt += """

        TASK:
        1. Summarize the plot in 2-3 engaging sentences (avoid spoilers)
        2. Highlight what makes it unique or notable
        3. Explain why this user might (or might not) enjoy it based on their preferences
        4. Only mention similar titles if the user explicitly asked for "similar/in stile/like"

        Be conversational, friendly, and cozy. Keep it tight (under ~180 words).
        """

        return prompt
    }

    /// Build prompt for recommendation query
    func buildRecommendationPrompt(
        context: String?,
        userProfile: UserProfile?,
        conversationHistory: [AIChatMessage] = []
    ) -> String {
        var prompt = "RECOMMENDATION REQUEST:\n"

        if let context = context {
            prompt += "User Query Context: \(context)\n"
        } else {
            prompt += "User wants general recommendations\n"
        }

        if let profile = userProfile {
            prompt += "\n" + buildUserContext(userProfile: profile)
        }

        if !conversationHistory.isEmpty {
            prompt += "\nCONVERSATION HISTORY:\n"
            let recentHistory = conversationHistory.suffix(5)
            for message in recentHistory {
                let role = message.role == .user ? "User" : "Assistant"
                let content = message.content.prefix(100)
                prompt += "- \(role): \(content)\(message.content.count > 100 ? "..." : "")\n"
            }
        }

        prompt += """

        INSTRUCTIONS:
        - Recommend 3-5 movies or TV shows personalized to this user's taste
        - For each recommendation provide:
          1. Title and Year
          2. Why it matches their preferences (reference their liked genres/movies)
          3. One-sentence hook to entice them

        - Prioritize diversity in recommendations (different genres, decades, styles)
        - Avoid movies they've already watched or disliked
        - Be enthusiastic and conversational

        Format each recommendation as:
        [Title] ([Year])
        [One-sentence pitch]
        Why: [Personalized reason based on user profile]
        """

        return prompt
    }

    /// Build prompt for mood-based query
    func buildMoodPrompt(
        mood: Mood,
        userProfile: UserProfile?
    ) -> String {
        var prompt = """
        MOOD-BASED RECOMMENDATION:
        User is feeling: \(mood.displayName)
        """

        if let profile = userProfile {
            let topGenres = profile.topGenres.prefix(3).map { $0.genreName }.joined(separator: ", ")
            prompt += """

            USER PREFERENCES:
            - Favorite Genres: \(topGenres)
            - Content Type: \(profile.contentTypePreference.movieRatio > 0.6 ? "Prefers Movies" : profile.contentTypePreference.tvRatio > 0.6 ? "Prefers TV Shows" : "Balanced")
            """
        }

        prompt += """

        TASK:
        Recommend 3-5 movies or TV shows that match the user's current mood: \(mood.rawValue).

        Consider:
        - The emotional tone they're seeking
        - Their genre preferences (but adapt to mood)
        - Mix of familiar comfort content and fresh discoveries

        For each recommendation:
        1. Title and Year
        2. Why it fits the mood
        3. Emotional benefit (e.g., "Will lift your spirits", "Perfect for a cozy night")

        Be empathetic and understanding of their emotional state.
        """

        return prompt
    }

    /// Build prompt for comparison query
    func buildComparisonPrompt(
        items: [String],
        userProfile: UserProfile?
    ) -> String {
        var prompt = """
        COMPARISON REQUEST:
        Compare: \(items.joined(separator: " vs "))
        """

        if let profile = userProfile {
            let topGenres = profile.topGenres.prefix(3).map { $0.genreName }.joined(separator: ", ")
            prompt += """

            USER PREFERENCES:
            - Favorite Genres: \(topGenres)
            """
        }

        prompt += """

        TASK:
        Provide a balanced comparison of these movies/shows:

        For each item:
        1. Brief description
        2. Strengths and unique qualities
        3. Target audience

        Then provide:
        - Similarities between them
        - Key differences
        - Personal recommendation based on user's taste (if profile available)

        Be objective but helpful. Keep response under 250 words.
        """

        return prompt
    }

    /// Build prompt for availability query
    func buildAvailabilityPrompt(
        title: String,
        region: String?
    ) -> String {
        var prompt = """
        AVAILABILITY QUERY:
        User wants to know where to watch: \(title)
        """

        if let region = region {
            prompt += "\nRegion: \(region)"
        }

        prompt += """

        TASK:
        Unfortunately, as an AI I don't have real-time access to streaming availability data.

        Provide a helpful response that:
        1. Acknowledges you can't check live availability
        2. Suggests common platforms where this type of content is typically found
        3. Recommends using JustWatch.com or similar services to check current availability
        4. Optionally mention if it's a recent release, classic, or platform exclusive (if you know)

        Keep response friendly and helpful despite the limitation.
        """

        return prompt
    }

    // MARK: - New Personalization Prompts

    /// Build prompt for rewriting movie loglines
    func buildLoglineRewritePrompt(
        movie: MovieDetails,
        userProfile: UserProfile
    ) -> String {
        var prompt = """
        TASK: Rewrite the plot summary for "\(movie.title)" to specifically appeal to this user.

        MOVIE:
        - Title: \(movie.title)
        - Overview: \(movie.overview ?? "")
        - Genres: \(movie.genres?.map { $0.name }.joined(separator: ", ") ?? "")

        USER PROFILE:
        """
        
        prompt += buildUserProfileSection(userProfile)
        
        prompt += """

        INSTRUCTIONS:
        - Write ONE engaging sentence (max 25 words).
        - Focus on elements the user loves (e.g., if they like sci-fi, highlight the sci-fi aspects; if they like drama, focus on the emotional stakes).
        - Do NOT simply summarize; SELL the movie to this specific user.
        - Adopt a tone that matches the user's inferred preference (e.g., exciting, mysterious, or heartwarming).
        - Do NOT include the movie title in the output.
        - Do NOT use reasoning tags.
        """
        
        return prompt
    }

    /// Build prompt for micro-analysis of recent interactions
    func buildMicroAnalysisPrompt(
        recentInteractions: [String] // Simplified interaction descriptions for prompt
    ) -> String {
        let interactionsList = recentInteractions.joined(separator: "\n")
        
        return """
        TASK: Analyze these recent user interactions to detect their current mood/vibe.

        RECENT INTERACTIONS (Last 10 minutes):
        \(interactionsList)

        INSTRUCTIONS:
        - Identify the immediate pattern (e.g., "Skipping horror, looking for comedy", "Deep diving into 80s action").
        - Determine which genres or moods should be boosted or suppressed RIGHT NOW.
        - Return a JSON object with weight adjustments.

        FORMAT:
        {
            "boost_genres": ["Comedy", "Romance"],
            "suppress_genres": ["Horror", "Thriller"],
            "current_vibe": "Lighthearted escapism"
        }
        
        Only return the JSON. No markdown formatting.
        """
    }

    /// Build prompt for "Why For Me?" explanation
    func buildWhyForMePrompt(
        movie: MovieDetails,
        userProfile: UserProfile
    ) -> String {
        var prompt = """
        TASK: Explain why the user should watch "\(movie.title)" based on their unique profile.

        MOVIE:
        - Title: \(movie.title)
        - Overview: \(movie.overview ?? "")
        - Genres: \(movie.genres?.map { $0.name }.joined(separator: ", ") ?? "")
        """
        
        if let cast = movie.credits?.cast?.prefix(3).map({ $0.name }).joined(separator: ", ") {
            prompt += "\n- Cast: \(cast)"
        }
        
        prompt += "\n\nUSER PROFILE:\n"
        prompt += buildUserProfileSection(userProfile)
        
        prompt += """

        INSTRUCTIONS:
        - Produce three different, useful explanations: one for mood, one for genres/story elements, and one for cast.
        - Personalize each section with the user's profile whenever matching data is available.
        - If user-profile data is insufficient for a section, still write a sensible explanation based on the movie/show metadata. Never copy another section and never leave a section empty.
        - Each value must be one concise sentence in non-technical, friendly language.
        - The mood value should describe tone, atmosphere, pacing, or emotional fit.
        - The genres value should explain the appeal of the genres, themes, or story elements.
        - The cast value should mention relevant cast members or, when cast metadata is unavailable, the characters or ensemble appeal.
        - Be persuasive but honest. Do not claim that the user knows or likes an actor unless the profile supports it.
        - Do NOT use reasoning tags or markdown.

        OUTPUT JSON:
        {"mood":"...","genres":"...","cast":"..."}
        """
        
        return prompt
    }

    /// Build prompt for Smart Nudge notification
    func buildSmartNudgePrompt(
        userProfile: UserProfile,
        candidates: [String] // List of candidate titles (e.g. from watchlist/abandoned)
    ) -> String {
        var prompt = """
        TASK: Generate a personalized push notification to bring the user back to the app.

        CANDIDATE CONTENT (Watchlist/Abandoned):
        \(candidates.joined(separator: ", "))

        USER PROFILE:
        """
        
        prompt += buildUserProfileSection(userProfile)
        
        prompt += """

        INSTRUCTIONS:
        - Choose ONE item from the candidates that fits the user's profile best.
        - Write a short, punchy notification message (max 15 words).
        - Don't just say "Watch this." Give a reason (e.g., "Perfect for a rainy Tuesday," "Finish what you started," "The plot twist awaits").
        - Tone: Friendly, nudge, not spammy.
        - Output format: "Title: Message"
        - Do NOT use reasoning tags.
        """
        
        return prompt
    }

    // MARK: - Private Methods

    private func baseSystemPrompt() -> String {
        """
        You are VibeWatch AI, a cozy movie-holic friend inside the VibeWatch app.

        YOUR PERSONALITY:
        - Talk like a close friend or "bro" talking about movies.
        - Warm, friendly, and very casual.
        - Enthusiastic about movies and TV shows.
        - Knowledgeable but never pretentious.
        - Use natural language.
        - Respects user preferences and taste.

        CORE PRINCIPLES:
        - Always prioritize user's preferences and viewing history
        - Provide diverse recommendations to prevent filter bubbles
        - Be honest about limitations (e.g., can't check live streaming availability)
        - Start with the DIRECT answer to what the user asked
        - Keep responses concise by default; go deeper only when the user asks

        CRITICAL FORMATTING RULES (STRICTLY ENFORCED):
        - **NEVER** use asterisks (*) for emphasis, bolding, or lists.
        - **NEVER** use markdown headers (#) or bullet points.
        - Write in plain text paragraphs, like a text message to a friend.
        - Use emojis sparingly to convey tone.
        - Do NOT include any reasoning, thought process, or explanations in your response.
        - Do NOT use <think> tags.

        CRITICAL BEHAVIOR RULES:
        - ALWAYS respond in the SAME LANGUAGE as the user's last message.
        - If the user asks about ONE specific title (info/explanation), do NOT list extra recommendations unless explicitly requested.
        - Only provide 3-5 recommendations when the user explicitly asks for recommendations (e.g., "consigliami", "recommend", "similar", "in stile", "like").
        """
    }

    private func buildUserProfileSection(_ profile: UserProfile) -> String {
        var section = "USER PROFILE:"

        if !profile.topGenres.isEmpty {
            let genres = profile.topGenres.prefix(5)
                .map { "\($0.genreName) (score: \(String(format: "%.1f", $0.totalScore)))" }
                .joined(separator: ", ")
            section += "\n- Top Genres: \(genres)"
        }

        if !profile.topActors.isEmpty {
            let actors = profile.topActors.prefix(5)
                .map { "\($0.name) (score: \(String(format: "%.1f", $0.score)))" }
                .joined(separator: ", ")
            section += "\n- Top Actors: \(actors)"
        }

        if !profile.preferredMoods.isEmpty {
            let moods = profile.preferredMoods.prefix(5)
                .map(\.rawValue)
                .joined(separator: ", ")
            section += "\n- Preferred Moods: \(moods)"
        }

        if !profile.recentActivity.watchedMedia.isEmpty {
            let watched = profile.recentActivity.watchedMedia
                .prefix(5)
                .map { "\($0.title)\($0.year.map { " (\($0))" } ?? "")" }
                .joined(separator: ", ")
            section += "\n- Recently Watched: \(watched)"
        }

        if !profile.recentActivity.likedMedia.isEmpty {
            let liked = profile.recentActivity.likedMedia
                .prefix(3)
                .map { $0.title }
                .joined(separator: ", ")
            section += "\n- Liked: \(liked)"
        }

        if let lastSearch = profile.recentActivity.lastSearchQuery {
            section += "\n- Last Search: \"\(lastSearch)\""
        }

        if !profile.recentActivity.discoveryClicks.isEmpty {
            let clicks = profile.recentActivity.discoveryClicks
                .prefix(3)
                .map { $0.title }
                .joined(separator: ", ")
            section += "\n- Recently Explored: \(clicks)"
        }

        // Watch patterns
        if profile.watchPatterns.completionRate > 0 {
            let completionPercentage = Int(profile.watchPatterns.completionRate * 100)
            section += "\n- Watch Completion Rate: \(completionPercentage)%"
        }

        return section
    }

    private func buildTaskSection(queryType: QueryType) -> String {
        switch queryType {
        case .specificMedia:
            return """
            TASK: Provide detailed information about a specific movie/show
            - Be informative and engaging
            - Highlight why it's notable
            - Personalize based on user's taste
            - Avoid spoilers unless asked
            - Do NOT recommend other titles unless explicitly requested
            """

        case .informational:
            return """
            TASK: Answer a specific question about movies/shows
            - Be accurate and concise
            - Provide context if helpful
            - Cite specific examples
            - Do NOT include extra recommendations unless asked
            """

        case .comparison:
            return """
            TASK: Compare movies/shows objectively
            - Highlight strengths of each
            - Point out key differences
            - Provide personalized recommendation
            """

        case .recommendation:
            return """
            TASK: Recommend personalized content
            - Suggest 3-5 options
            - Explain why each fits user's taste
            - Ensure diversity in recommendations
            - Be enthusiastic but honest
            """

        case .moodBased:
            return """
            TASK: Recommend content matching user's mood
            - Consider emotional tone
            - Balance user preferences with mood fit
            - Provide emotional benefit explanation
            - Be empathetic and understanding
            """

        case .availability:
            return """
            TASK: Help user find where to watch content
            - Acknowledge limitation (no live data)
            - Suggest checking platforms/services
            - Provide helpful alternatives
            """
        }
    }
}

// MARK: - Supporting Models

struct MovieDetails: Codable {
    let id: Int
    let title: String
    let overview: String?
    let releaseDate: String?
    let voteAverage: Double
    let voteCount: Int
    let runtime: Int?
    let genres: [Genre]?
    let credits: Credits?

    struct Genre: Codable {
        let id: Int
        let name: String
    }

    struct Credits: Codable {
        let cast: [CastMember]?
        let crew: [CrewMember]?
    }

    struct CastMember: Codable {
        let id: Int
        let name: String
        let character: String?
    }

    struct CrewMember: Codable {
        let id: Int
        let name: String
        let job: String
    }
}

/// Structured AI output for the three independent cards shown in "Why for me".
struct WhyForMeAnalysis: Codable, Equatable, Sendable {
    let mood: String
    let genres: String
    let cast: String

    var isCompleteAndDistinct: Bool {
        let sections = [mood, genres, cast]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return sections.allSatisfy { $0.count >= 10 }
            && Set(sections.map { $0.lowercased() }).count == sections.count
    }
}
