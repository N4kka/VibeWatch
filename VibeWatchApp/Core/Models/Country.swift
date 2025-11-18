import Foundation

struct Country: Identifiable, Codable, Hashable {
    let id: String // ISO country code (e.g., "US", "IT")
    let name: String
    let flag: String // Emoji flag
    let nativeLanguageCode: String // Primary language code
    
    static let all: [Country] = [
        Country(id: "US", name: "United States", flag: "🇺🇸", nativeLanguageCode: "en"),
        Country(id: "GB", name: "United Kingdom", flag: "🇬🇧", nativeLanguageCode: "en"),
        Country(id: "CA", name: "Canada", flag: "🇨🇦", nativeLanguageCode: "en"),
        Country(id: "AU", name: "Australia", flag: "🇦🇺", nativeLanguageCode: "en"),
        Country(id: "IT", name: "Italy", flag: "🇮🇹", nativeLanguageCode: "it"),
        Country(id: "ES", name: "Spain", flag: "🇪🇸", nativeLanguageCode: "es"),
        Country(id: "FR", name: "France", flag: "🇫🇷", nativeLanguageCode: "fr"),
        Country(id: "DE", name: "Germany", flag: "🇩🇪", nativeLanguageCode: "de"),
        Country(id: "JP", name: "Japan", flag: "🇯🇵", nativeLanguageCode: "ja"),
        Country(id: "KR", name: "South Korea", flag: "🇰🇷", nativeLanguageCode: "ko"),
        Country(id: "CN", name: "China", flag: "🇨🇳", nativeLanguageCode: "zh"),
        Country(id: "BR", name: "Brazil", flag: "🇧🇷", nativeLanguageCode: "pt"),
        Country(id: "MX", name: "Mexico", flag: "🇲🇽", nativeLanguageCode: "es"),
        Country(id: "AR", name: "Argentina", flag: "🇦🇷", nativeLanguageCode: "es"),
        Country(id: "IN", name: "India", flag: "🇮🇳", nativeLanguageCode: "hi"),
        Country(id: "RU", name: "Russia", flag: "🇷🇺", nativeLanguageCode: "ru"),
        Country(id: "NL", name: "Netherlands", flag: "🇳🇱", nativeLanguageCode: "nl"),
        Country(id: "SE", name: "Sweden", flag: "🇸🇪", nativeLanguageCode: "sv"),
        Country(id: "NO", name: "Norway", flag: "🇳🇴", nativeLanguageCode: "no"),
        Country(id: "DK", name: "Denmark", flag: "🇩🇰", nativeLanguageCode: "da"),
        Country(id: "FI", name: "Finland", flag: "🇫🇮", nativeLanguageCode: "fi"),
        Country(id: "PL", name: "Poland", flag: "🇵🇱", nativeLanguageCode: "pl"),
        Country(id: "TR", name: "Turkey", flag: "🇹🇷", nativeLanguageCode: "tr"),
        Country(id: "GR", name: "Greece", flag: "🇬🇷", nativeLanguageCode: "el"),
        Country(id: "PT", name: "Portugal", flag: "🇵🇹", nativeLanguageCode: "pt"),
    ]
    
    static func findByCode(_ code: String) -> Country? {
        return all.first { $0.id == code }
    }
}

struct Language: Identifiable, Codable, Hashable {
    let id: String // ISO language code (e.g., "en", "it")
    let name: String // Name in English
    let nativeName: String // Name in native language
    
    static let all: [Language] = [
        Language(id: "en", name: "English", nativeName: "English"),
        Language(id: "it", name: "Italian", nativeName: "Italiano"),
        Language(id: "es", name: "Spanish", nativeName: "Español"),
        Language(id: "fr", name: "French", nativeName: "Français"),
        Language(id: "de", name: "German", nativeName: "Deutsch"),
        Language(id: "ja", name: "Japanese", nativeName: "日本語"),
        Language(id: "ko", name: "Korean", nativeName: "한국어"),
        Language(id: "zh", name: "Chinese", nativeName: "中文"),
        Language(id: "pt", name: "Portuguese", nativeName: "Português"),
        Language(id: "hi", name: "Hindi", nativeName: "हिन्दी"),
        Language(id: "ru", name: "Russian", nativeName: "Русский"),
        Language(id: "nl", name: "Dutch", nativeName: "Nederlands"),
        Language(id: "sv", name: "Swedish", nativeName: "Svenska"),
        Language(id: "no", name: "Norwegian", nativeName: "Norsk"),
        Language(id: "da", name: "Danish", nativeName: "Dansk"),
        Language(id: "fi", name: "Finnish", nativeName: "Suomi"),
        Language(id: "pl", name: "Polish", nativeName: "Polski"),
        Language(id: "tr", name: "Turkish", nativeName: "Türkçe"),
        Language(id: "el", name: "Greek", nativeName: "Ελληνικά"),
    ]
    
    static func findByCode(_ code: String) -> Language? {
        return all.first { $0.id == code }
    }
    
    // Get available languages for a country
    static func availableFor(country: Country) -> [Language] {
        var languages: [Language] = []
        
        // Add native language first
        if let nativeLang = findByCode(country.nativeLanguageCode) {
            languages.append(nativeLang)
        }
        
        // Add English if it's not already the native language
        if country.nativeLanguageCode != "en", let english = findByCode("en") {
            languages.append(english)
        }
        
        return languages
    }
}
