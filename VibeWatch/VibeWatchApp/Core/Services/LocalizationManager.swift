import Foundation
import SwiftUI

class LocalizationManager: ObservableObject {
    @MainActor static let shared = LocalizationManager()

    @Published var currentCountry: Country
    @Published var currentLanguage: Language
    @Published var localeDidChange: Bool = false // Triggers refresh when locale changes

    // Use UserDefaults directly to avoid @AppStorage initialization issues
    private var selectedCountryCode: String {
        get { UserDefaults.standard.string(forKey: "selectedCountryCode") ?? "US" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedCountryCode") }
    }

    private var selectedLanguageCode: String {
        get { UserDefaults.standard.string(forKey: "selectedLanguageCode") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLanguageCode") }
    }

    private init() {
        // Initialize with saved values or device defaults
        let savedCountryCode = UserDefaults.standard.string(forKey: "selectedCountryCode")
        let savedLanguageCode = UserDefaults.standard.string(forKey: "selectedLanguageCode")

        let deviceCountryCode: String
        let deviceLanguageCode: String

        if savedCountryCode == nil || savedLanguageCode == nil {
            let locale = Locale.current
            deviceCountryCode = locale.region?.identifier ?? "US"
            deviceLanguageCode = locale.language.languageCode?.identifier ?? "en"

            if savedCountryCode == nil {
                UserDefaults.standard.set(deviceCountryCode, forKey: "selectedCountryCode")
            }
            if savedLanguageCode == nil {
                UserDefaults.standard.set(deviceLanguageCode, forKey: "selectedLanguageCode")
            }
        } else {
            deviceCountryCode = savedCountryCode!
            deviceLanguageCode = savedLanguageCode!
        }

        self.currentCountry = Country.findByCode(deviceCountryCode) ?? Country.all[0]
        self.currentLanguage = Language.findByCode(deviceLanguageCode) ?? Language.all[0]

        print("🌍 Localization initialized: Country=\(currentCountry.name), Language=\(currentLanguage.name)")
    }

    func setCountry(_ country: Country) {
        currentCountry = country
        selectedCountryCode = country.id

        if let nativeLang = Language.findByCode(country.nativeLanguageCode) {
            currentLanguage = nativeLang
            selectedLanguageCode = nativeLang.id
            print("🌍 Language automatically changed to native: \(nativeLang.name)")
        }

        localeDidChange.toggle()
        objectWillChange.send()

        print("🌍 Country changed to: \(country.name)")
    }

    func setLanguage(_ language: Language) {
        currentLanguage = language
        selectedLanguageCode = language.id

        localeDidChange.toggle()
        objectWillChange.send()

        print("🌍 Language changed to: \(language.name)")
    }

    func localized(_ key: String) -> String {
        // Find the path for the language code
        if let path = Bundle.main.path(forResource: currentLanguage.id, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            // Return the localized string from the specific bundle
            return NSLocalizedString(key, tableName: nil, bundle: bundle, comment: "")
        }

        // Fallback to the default/base localization (English)
        return NSLocalizedString(key, comment: "")
    }
}

// Helper extension for easy access to localized strings
extension String {
    var localized: String {
        LocalizationManager.shared.localized(self)
    }
}
