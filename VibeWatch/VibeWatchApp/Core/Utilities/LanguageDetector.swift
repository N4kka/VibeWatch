import Foundation
import NaturalLanguage

@MainActor
final class LanguageDetector {
    static let shared = LanguageDetector()
    
    private init() {}
    
    /// Detects the dominant language of a given text.
    /// - Parameter text: The string to analyze.
    /// - Returns: A two-letter ISO 639-1 language code (e.g., "en", "it", "es", "fr") if detected, otherwise nil.
    func detectLanguage(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        if let (language, confidence) = hypotheses.max(by: { $0.value < $1.value }),
           confidence >= 0.25,
           language.rawValue != "und" {
            return language.rawValue
        }

        // Fallback heuristic for short / ambiguous inputs (helps when user switches language mid-session).
        let lower = trimmed.lowercased()
        let italianHints: [String] = [
            "che ", "cosa ", "consigliami", "dovrei", "film", "serie", "stagioni", "perché", "mi ", "voglio", "vorrei"
        ]
        let englishHints: [String] = [
            "what ", "think", "about", "recommend", "movie", "show", "series", "should", "where", "like", "similar"
        ]

        let itScore = italianHints.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        let enScore = englishHints.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }

        if itScore > enScore, itScore > 0 { return "it" }
        if enScore > itScore, enScore > 0 { return "en" }

        return recognizer.dominantLanguage?.rawValue == "und" ? nil : recognizer.dominantLanguage?.rawValue
    }
}
