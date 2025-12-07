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
        // Ensure the text is not too short, as detection can be unreliable for very short strings.
        guard text.count >= 5 else { return nil }
        
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        
        // Get the dominant language. The confidence threshold can be adjusted.
        if let languageCode = recognizer.dominantLanguage?.rawValue {
            // NLLanguage.rawValue returns BCP-47 codes (e.g., "en", "it", "es", "fr").
            // We can directly use these as they match the ISO 639-1 format we want.
            return languageCode
        }
        
        return nil
    }
}
