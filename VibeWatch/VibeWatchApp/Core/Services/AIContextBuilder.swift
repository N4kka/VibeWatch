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

    /// The volatile half of every chat request: what the model must not be asked to remember.
    ///
    /// It lives in the user turn, never in the system prompt: context caching matches on a
    /// prefix, so anything that changes per request would stop every request from ever hitting
    /// the cache. The persona, the format and the vibe-json contract are the stable half and
    /// live in the gateway (`cerebras-proxy/quota.ts`), identical byte for byte on every call.
    ///
    /// The markers are terse on purpose. With a low reasoning effort the model follows data far
    /// better than it follows prose, and the measured failures were all missing data, not
    /// missing instructions: without `[title]` it got the release year wrong every time and
    /// credited a director with other people's films; without `[reply in]` it never switched
    /// language on its own.
    func buildUserTurn(
        query: String,
        userProfile: UserProfile?,
        seenTitles: [String] = [],
        savedEntries: [SavedEntry] = [],
        activeFilters: [AIChatFilter] = [],
        media: (details: MovieDetails, kind: MediaType)? = nil,
        availability: String? = nil,
        releases: String? = nil,
        languageName: String? = nil
    ) -> String {
        var lines: [String] = []

        if let profile = userProfile {
            // Names only: the numeric genre scores were noise the model had to parse and never
            // used, and they cost tokens on every single request.
            let loves = profile.topGenres.prefix(3).map(\.genreName)
                + profile.topActors.prefix(2).map(\.name)
            if !loves.isEmpty {
                lines.append("[you know] loves: \(loves.joined(separator: ", "))")
            }

            let watched = profile.recentActivity.watchedMedia.prefix(3).map(\.title)
            if !watched.isEmpty {
                lines.append("[you know] just watched: \(watched.joined(separator: ", "))")
            }
        }

        // A hint, not the guard. The hard exclusion is applied in code when the cards are
        // resolved, which is why the list can be short instead of forty titles long.
        if !seenTitles.isEmpty {
            lines.append("[skip] \(seenTitles.prefix(seenTitlesHint).joined(separator: ", "))")
        }

        // Deliberately NOT merged into [skip], which is where it used to live. What the user
        // saved and has not watched yet is the opposite of an exclusion: answering "what should
        // I watch tonight" out of their own watchlist is the best answer there is, and merging
        // the two lists is why "recommend something from my watchlist" came back with three
        // titles from nowhere — the only reply consistent with what we had told the model.
        if !savedEntries.isEmpty {
            let entries = savedEntries.prefix(savedEntriesCap).map(savedLine)
            lines.append("[saved] \(entries.joined(separator: "; "))")
        }

        if let media {
            lines.append("[title] \(mediaLine(media.details, kind: media.kind))")
        }

        if let availability, !availability.isEmpty {
            lines.append("[watch] \(availability)")
        }

        // Without it "what's out in cinemas in September" got "I don't have real-time data".
        if let releases {
            lines.append("[releases] \(releases)")
        }

        for filter in activeFilters {
            lines.append("[only] \(filterLine(filter))")
        }

        if let languageName {
            lines.append("[reply in] \(languageName)")
        }

        guard !lines.isEmpty else { return query }
        return lines.joined(separator: "\n") + "\n\n" + query
    }

    /// How many already-seen titles are worth naming. The model only needs enough to steer away
    /// from the obvious repeats; `resolveCards` drops the rest for real.
    private let seenTitlesHint = 12

    /// Saved titles are the opposite: they are the answer, not a filter, so the cap is what the
    /// model can actually choose from. Twenty-five entries with runtime cost ~150 tokens.
    private let savedEntriesCap = 25

    /// One entry of the user's own curation: watchlist plus custom lists.
    ///
    /// `tmdbId` e `mediaType` non finiscono mai nel prompt — servono al codice: se il modello
    /// nomina un titolo che sta qui, la card si costruisce con questo id invece di cercarlo su
    /// TMDB per nome, che su un titolo ambiguo aggancia il film sbagliato.
    struct SavedEntry {
        let tmdbId: Int
        let mediaType: MediaType
        let title: String
        let year: Int?
        /// Movies only — for a show the per-episode runtime would answer the wrong question.
        let runtime: Int?
        /// Nil for the watchlist (the default, left untagged to save tokens); the list name for
        /// a custom list, so "recommend from my horror list" has something to match on.
        let listName: String?
    }

    private func savedLine(_ entry: SavedEntry) -> String {
        var line = entry.year.map { "\(entry.title) (\($0))" } ?? entry.title
        if let runtime = entry.runtime, runtime > 0 { line += " · \(runtime)min" }
        if let listName = entry.listName { line += " · \(listName)" }
        return line
    }

    private func mediaLine(_ details: MovieDetails, kind: MediaType) -> String {
        var parts: [String] = []

        let year = details.releaseDate?.prefix(4)
        parts.append(year.map { "\(details.title) (\($0))" } ?? details.title)
        parts.append(kind == .tv ? "tv" : "movie")

        if let director = details.credits?.crew?.first(where: { $0.job == "Director" }) {
            parts.append(director.name)
        }
        if let genres = details.genres?.prefix(3).map(\.name), !genres.isEmpty {
            parts.append(genres.joined(separator: ", "))
        }
        if details.voteCount > 0 {
            parts.append(String(format: "%.1f/10", details.voteAverage))
        }
        if let runtime = details.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        if let cast = details.credits?.cast?.prefix(4).map(\.name), !cast.isEmpty {
            parts.append("cast: \(cast.joined(separator: ", "))")
        }

        return parts.joined(separator: " · ")
    }

    private func filterLine(_ filter: AIChatFilter) -> String {
        switch filter {
        case .myPlatforms(let names):
            return "titles streaming on \(names.joined(separator: ", "))"
        case .recent:
            return "titles released in the last 3 years"
        case .shorter:
            return "movies under 100 minutes, or shows with at most 2 seasons"
        case .hiddenGems:
            return "well-rated but lesser-known titles, no mainstream blockbusters"
        }
    }

    /// Il profilo in forma discorsiva, usato dai prompt aux (loglines, why-for-me, nudge).
    /// La chat NON passa piu' di qui: li' il profilo e' una riga secca nel turno utente.
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

        if profile.watchPatterns.completionRate > 0 {
            let completionPercentage = Int(profile.watchPatterns.completionRate * 100)
            section += "\n- Watch Completion Rate: \(completionPercentage)%"
        }

        return section
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
