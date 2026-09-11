import Foundation
import SwiftUI

final class LocalizationManager: ObservableObject {
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

        Logger.debug("[Localization] Localization initialized: Country=\(currentCountry.name), Language=\(currentLanguage.name)")
    }

    func setCountry(_ country: Country) {
        let previousLanguageId = currentLanguage.id
        currentCountry = country
        selectedCountryCode = country.id

        if let nativeLang = Language.findByCode(country.nativeLanguageCode) {
            currentLanguage = nativeLang
            selectedLanguageCode = nativeLang.id
            Logger.debug("[Localization] Language automatically changed to native: \(nativeLang.name)")
            if previousLanguageId != nativeLang.id {
                Task { @MainActor in
                    AnalyticsService.shared.logLanguageChanged(from: previousLanguageId, to: nativeLang.id)
                }
            }
        }

        localeDidChange.toggle()
        objectWillChange.send()
        syncLocaleToNotificationBackend()

        Logger.debug("[Localization] Country changed to: \(country.name)")
    }

    func setLanguage(_ language: Language) {
        let previousLanguageId = currentLanguage.id
        currentLanguage = language
        selectedLanguageCode = language.id

        localeDidChange.toggle()
        objectWillChange.send()

        if previousLanguageId != language.id {
            Task { @MainActor in
                AnalyticsService.shared.logLanguageChanged(from: previousLanguageId, to: language.id)
            }
        }
        syncLocaleToNotificationBackend()

        Logger.debug("[Localization] Language changed to: \(language.name)")
    }

    /// Push and email copy is rendered server-side, in the language stored alongside the user's
    /// notification preferences — so a language change in the app has to reach that row, or the
    /// next notification arrives in the language the user just left.
    private func syncLocaleToNotificationBackend() {
        Task { @MainActor in
            await NotificationService.shared.syncPreferencesToSupabase(NotificationPreferencesStore.load())
        }
    }

    // Opt out of main-actor isolation for this pure lookup method.
    // It reads currentLanguage.id and does a bundle lookup; acceptable for our use.
    nonisolated(unsafe) func localized(_ key: String) -> String {
        // Find the path for the language code
        if let path = Bundle.main.path(forResource: currentLanguage.id, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            // Return the localized string from the specific bundle
            let localized = NSLocalizedString(key, tableName: nil, bundle: bundle, comment: "")
            if localized != key {
                return localized
            }

            // If the key is missing in the selected localization, fallback to the default (English)
            return NSLocalizedString(key, comment: "")
        }

        // Fallback to the default/base localization (English)
        return NSLocalizedString(key, comment: "")
    }
    
    /// Il `Locale` che corrisponde alla lingua **scelta in-app**, non a quella del dispositivo.
    ///
    /// Serve ovunque si chieda a Foundation di formattare qualcosa per l'utente: nomi di paese e
    /// di lingua, date. Usare `Locale.current` lì funziona solo finché lingua di sistema e lingua
    /// scelta coincidono — su un iPhone in inglese con l'app in italiano la scheda film tornava a
    /// dire "English" e "July 15, 2026".
    ///
    /// `nonisolated(unsafe)` per la stessa ragione di `localized(_:)`: è una lettura pura di due
    /// stringhe già in memoria, chiamata anche da formatter non main-actor.
    nonisolated(unsafe) var appLocale: Locale {
        Locale(identifier: "\(currentLanguage.id)_\(currentCountry.id)")
    }

    @MainActor
    func currentLanguageAndRegion() -> (String, String) {
        (currentLanguage.id, currentCountry.id)
    }
    
    @MainActor
    func currentLanguageCode() -> String {
        currentLanguage.id
    }
}

// Helper extension for easy access to localized strings
extension String {
    // Nonisolated so it can be used from any thread/actor (e.g., enums, models).
    nonisolated var localized: String {
        LocalizationManager.shared.localized(self)
    }
}

// Since .localized is now nonisolated and safe, this extra helper is no longer needed,
// but if you want to keep the API, make it nonisolated and just forward.
extension String {
    nonisolated func localizedMainSafe() -> String {
        LocalizationManager.shared.localized(self)
    }
}
