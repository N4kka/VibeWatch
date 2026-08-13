import Foundation
import NaturalLanguage

/// Service for classifying AI chatbot queries and extracting entities
/// Uses NaturalLanguage framework for intent detection and entity recognition
class AIQueryClassifier {
    static let shared = AIQueryClassifier()

    // MARK: - Properties

    private let tagger: NLTagger
    private let genreKeywords: [String: [String]]
    private let moodKeywords: [String: Mood]

    // MARK: - Initialization

    private init() {
        // Initialize NLTagger for entity recognition
        self.tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])

        // Genre keyword mapping
        self.genreKeywords = [
            "action": ["action", "fight", "combat", "explosion", "chase"],
            "comedy": ["comedy", "funny", "laugh", "hilarious", "humor"],
            "drama": ["drama", "emotional", "serious", "touching"],
            "horror": ["horror", "scary", "frightening", "terrifying", "spooky"],
            "romance": ["romance", "romantic", "love", "relationship"],
            "sci-fi": ["sci-fi", "science fiction", "futuristic", "space", "alien"],
            "thriller": ["thriller", "suspense", "tense", "mystery"],
            "fantasy": ["fantasy", "magic", "wizard", "dragon", "medieval"],
            "documentary": ["documentary", "documentary", "real", "true story"],
            "animation": ["animation", "animated", "cartoon"]
        ]

        // Mood keyword mapping
        self.moodKeywords = [
            "happy": .happy,
            "joyful": .happy,
            "cheerful": .happy,
            "sad": .sad,
            "depressed": .sad,
            "melancholy": .sad,
            "excited": .excited,
            "thrilled": .excited,
            "pumped": .excited,
            "relaxed": .relaxed,
            "calm": .relaxed,
            "chill": .relaxed,
            "scared": .scared,
            "frightened": .scared,
            "terrified": .scared,
            "thoughtful": .thoughtful,
            "pensive": .thoughtful,
            "contemplative": .thoughtful,
            "romantic": .romantic,
            "loving": .romantic,
            "adventurous": .adventurous,
            "daring": .adventurous,
            "nostalgic": .nostalgic,
            "sentimental": .nostalgic,
            "energetic": .energetic,
            "lively": .energetic
        ]

        Logger.info("[AIQueryClassifier] Initialized")
    }

    // MARK: - Public Methods

    /// Classify a user query into its type and extract entities
    func classify(query: String) -> QueryClassification {
        let lowercased = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        Logger.debug("[AIQueryClassifier] Classifying query: '\(query)'")

        // Check for specific media queries (e.g., "Tell me about Inception")
        if let mediaQuery = detectSpecificMediaQuery(lowercased) {
            return mediaQuery
        }

        // Check for informational queries (e.g., "Who directed The Matrix?")
        if let infoQuery = detectInformationalQuery(lowercased) {
            return infoQuery
        }

        // Check for comparison queries (e.g., "Is The Office better than Parks and Rec?")
        if let comparisonQuery = detectComparisonQuery(lowercased) {
            return comparisonQuery
        }

        // Check for availability queries (e.g., "Where can I watch Breaking Bad?")
        if let availabilityQuery = detectAvailabilityQuery(lowercased) {
            return availabilityQuery
        }

        // Check for mood-based queries (e.g., "I'm feeling sad")
        if let moodQuery = detectMoodQuery(lowercased) {
            return moodQuery
        }

        // Check for genre-based queries
        if let genreQuery = detectGenreQuery(lowercased) {
            return genreQuery
        }

        // Default to recommendation query
        let context = extractRecommendationContext(lowercased)
        return QueryClassification(
            type: .recommendation(context: context),
            confidence: 0.5,
            extractedEntities: extractEntities(from: query)
        )
    }

    // MARK: - Private Methods - Query Detection

    private func detectSpecificMediaQuery(_ query: String) -> QueryClassification? {
        let patterns = [
            "tell me about",
            "what is",
            "what's",
            "what do you think about",
            "what are your thoughts on",
            "thoughts on",
            "opinion on",
            "review of",
            "information about",
            "info about",
            "details about",
            "explain",
            "describe",
            // Italian
            "parlami di",
            "mi parli di",
            "dimmi di",
            "mi dici di",
            "che ne pensi di",
            "cosa ne pensi di",
            "che mi dici di",
            "opinione su",
            "informazioni su",
            "info su",
            "che cos'è",
            "cos'è",
            "spiegami",
            "descrivi"
        ]

        for pattern in patterns {
            if query.contains(pattern) {
                let rawTitle = extractMediaTitle(from: query, afterPattern: pattern)
                let (title, mediaTypeHint) = normalizeTitleAndInferMediaType(from: rawTitle, fullQuery: query)
                if !title.isEmpty {
                    return QueryClassification(
                        type: .specificMedia(title: title, mediaType: mediaTypeHint),
                        confidence: 0.9,
                        extractedEntities: ["title": title]
                    )
                }
            }
        }

        return nil
    }

    private func detectInformationalQuery(_ query: String) -> QueryClassification? {
        let patterns = [
            "who directed",
            "who stars in",
            "who acts in",
            "who is in",
            "when was",
            "when did",
            "what year",
            "how long",
            "how many seasons",
            "is it based on",
            // Italian
            "chi ha diretto",
            "chi è il regista",
            "chi recita in",
            "chi c'è in",
            "quando è uscito",
            "di che anno è",
            "quanto dura",
            "quante stagioni",
            "è basato su"
        ]

        for pattern in patterns {
            if query.contains(pattern) {
                return QueryClassification(
                    type: .informational(question: query),
                    confidence: 0.85,
                    extractedEntities: extractEntities(from: query)
                )
            }
        }

        return nil
    }

    private func detectComparisonQuery(_ query: String) -> QueryClassification? {
        let patterns = [
            "better than",
            "worse than",
            "compare",
            "versus",
            "vs",
            "or",
            "which is better"
        ]

        for pattern in patterns {
            if query.contains(pattern) {
                let items = extractComparisonItems(from: query)
                if items.count >= 2 {
                    return QueryClassification(
                        type: .comparison(items: items),
                        confidence: 0.9,
                        extractedEntities: ["items": items.joined(separator: ", ")]
                    )
                }
            }
        }

        return nil
    }

    private func detectAvailabilityQuery(_ query: String) -> QueryClassification? {
        let patterns = [
            "where can i watch",
            "where to watch",
            "how to watch",
            "is it on",
            "available on",
            "streaming on"
        ]

        for pattern in patterns {
            if query.contains(pattern) {
                let title = extractMediaTitle(from: query, afterPattern: pattern)
                if !title.isEmpty {
                    return QueryClassification(
                        type: .availability(title: title, region: nil),
                        confidence: 0.85,
                        extractedEntities: ["title": title]
                    )
                }
            }
        }

        return nil
    }

    private func detectMoodQuery(_ query: String) -> QueryClassification? {
        // Check for direct mood mentions
        for (keyword, mood) in moodKeywords {
            if query.contains(keyword) {
                return QueryClassification(
                    type: .moodBased(mood: mood),
                    confidence: 0.8,
                    extractedEntities: ["mood": mood.rawValue]
                )
            }
        }

        // Check for mood-indicating phrases
        let moodPatterns: [(String, Mood)] = [
            ("i'm feeling", .happy),
            ("i feel", .happy),
            ("feeling", .happy),
            ("i'm in the mood for", .happy),
            ("i want something", .happy)
        ]

        for (pattern, _) in moodPatterns {
            if query.contains(pattern) {
                // Try to extract specific mood from query
                if let detectedMood = detectMoodFromContext(query) {
                    return QueryClassification(
                        type: .moodBased(mood: detectedMood),
                        confidence: 0.75,
                        extractedEntities: ["mood": detectedMood.rawValue]
                    )
                }
            }
        }

        return nil
    }

    private func detectGenreQuery(_ query: String) -> QueryClassification? {
        for (genre, keywords) in genreKeywords {
            for keyword in keywords {
                if query.contains(keyword) {
                    let context = "Genre: \(genre)"
                    return QueryClassification(
                        type: .recommendation(context: context),
                        confidence: 0.7,
                        extractedEntities: ["genre": genre]
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Private Methods - Entity Extraction

    private func extractEntities(from text: String) -> [String: String] {
        var entities: [String: String] = [:]

        tagger.string = text

        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            if let tag = tag {
                let token = String(text[tokenRange])

                switch tag {
                case .personalName:
                    entities["person"] = token
                case .placeName:
                    entities["place"] = token
                case .organizationName:
                    entities["organization"] = token
                default:
                    break
                }
            }

            return true
        }

        return entities
    }

    private func extractMediaTitle(from query: String, afterPattern pattern: String) -> String {
        guard let range = query.range(of: pattern) else {
            return ""
        }

        let afterPattern = String(query[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer stopping at punctuation (multi-language).
        let punctuationStops: [Character] = ["?", "!", ".", ",", ";", ":"]
        if let stopIndex = afterPattern.firstIndex(where: { punctuationStops.contains($0) }) {
            return String(afterPattern[..<stopIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return afterPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeTitleAndInferMediaType(from rawTitle: String, fullQuery: String) -> (String, MediaType?) {
        var title = rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))

        // Infer media type from either the extracted title chunk or the full query.
        let mediaTypeHint = inferMediaType(from: title) ?? inferMediaType(from: fullQuery)

        // Strip common TV/movie qualifiers from the extracted title.
        title = stripMediaTypeQualifiers(from: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))

        return (title, mediaTypeHint)
    }

    private func inferMediaType(from text: String) -> MediaType? {
        let t = text.lowercased()
        if t.contains("tv show") || t.contains("tv series") || t.contains("tv") || t.contains("serie tv") || t.contains("serie") || t.contains("series") || t.contains("show") {
            return .tv
        }
        if t.contains("film") || t.contains("movie") {
            return .movie
        }
        return nil
    }

    private func stripMediaTypeQualifiers(from title: String) -> String {
        var cleaned = title
        let suffixes = [
            " tv show",
            " tv series",
            " tv",
            " show",
            " series",
            " serie tv",
            " serie",
            " serie televisiva"
        ]

        let lower = cleaned.lowercased()
        for suffix in suffixes {
            if lower.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                break
            }
        }

        // Also handle leading qualifiers like "the tv show Dexter" (rare but safe).
        let prefixes = [
            "tv show ",
            "tv series ",
            "show ",
            "series ",
            "serie tv ",
            "serie "
        ]
        for prefix in prefixes {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }

        return cleaned
    }

    private func extractComparisonItems(from query: String) -> [String] {
        // Split by comparison keywords
        let separators = [" or ", " vs ", " versus ", " and ", " better than ", " worse than "]
        var items: [String] = []

        var remaining = query
        for separator in separators {
            if remaining.contains(separator) {
                let parts = remaining.components(separatedBy: separator)
                if parts.count >= 2 {
                    items = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    break
                }
            }
        }

        // Clean up items (remove common prefixes)
        return items.map { item in
            let prefixes = ["is ", "the ", "a ", "an "]
            var cleaned = item
            for prefix in prefixes {
                if cleaned.hasPrefix(prefix) {
                    cleaned = String(cleaned.dropFirst(prefix.count))
                }
            }
            return cleaned.trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }

    private func extractRecommendationContext(_ query: String) -> String? {
        // Extract any specific requirements from the query
        if query.contains("like") {
            if let range = query.range(of: "like ") {
                let context = String(query[range.upperBound...])
                    .trimmingCharacters(in: .punctuationCharacters)
                return context
            }
        }

        if query.contains("similar to") {
            if let range = query.range(of: "similar to ") {
                let context = String(query[range.upperBound...])
                    .trimmingCharacters(in: .punctuationCharacters)
                return context
            }
        }

        return nil
    }

    private func detectMoodFromContext(_ query: String) -> Mood? {
        for (keyword, mood) in moodKeywords {
            if query.contains(keyword) {
                return mood
            }
        }
        return nil
    }
}

// MARK: - Supporting Models

struct QueryClassification {
    let type: QueryType
    let confidence: Double // 0.0-1.0
    let extractedEntities: [String: String]
}

enum QueryType {
    case specificMedia(title: String, mediaType: MediaType?)
    case informational(question: String)
    case comparison(items: [String])
    case recommendation(context: String?)
    case moodBased(mood: Mood)
    case availability(title: String, region: String?)

    /// Il nome piatto per la proprietà query_type di ai_chat_message_sent.
    var analyticsName: String {
        switch self {
        case .specificMedia: return "specific_media"
        case .informational: return "informational"
        case .comparison: return "comparison"
        case .recommendation: return "recommendation"
        case .moodBased: return "mood_based"
        case .availability: return "availability"
        }
    }

    var description: String {
        switch self {
        case .specificMedia(let title, _):
            return "Specific media query about '\(title)'"
        case .informational:
            return "Informational question"
        case .comparison(let items):
            return "Comparison between \(items.count) items"
        case .recommendation(let context):
            return "Recommendation request\(context.map { " (\($0))" } ?? "")"
        case .moodBased(let mood):
            return "Mood-based query (\(mood.rawValue))"
        case .availability(let title, _):
            return "Availability query for '\(title)'"
        }
    }
}
