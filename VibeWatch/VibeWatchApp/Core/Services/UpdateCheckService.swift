import Foundation

@MainActor
final class UpdateCheckService {
    static let shared = UpdateCheckService()

    private init() {}

    /// I tre campi che l'utente legge, in una lingua sola.
    ///
    /// Stessa forma in cima al JSON (la lingua di ripiego) e dentro ogni voce di `translations`,
    /// così scrivere una traduzione è copiare un blocco e cambiarne il contenuto.
    /// Non `private`: i test devono poter verificare la scelta della lingua.
    struct UpdateCopy: Decodable {
        let title: String?
        let message: String?
        let releaseNotes: [String]?

        enum CodingKeys: String, CodingKey {
            case title
            case message
            case releaseNotes = "release_notes"
        }
    }

    struct UpdateConfig: Decodable {
        let minimumVersion: String
        let latestVersion: String?
        let title: String?
        let message: String?
        let releaseNotes: [String]?
        /// Le traduzioni, per codice lingua ("it", "de", "pt-BR"…). Assente = solo ripiego.
        let translations: [String: UpdateCopy]?
        let appStoreURL: String?

        enum CodingKeys: String, CodingKey {
            case minimumVersion = "minimum_version"
            case latestVersion = "latest_version"
            case title
            case message
            case releaseNotes = "release_notes"
            case translations
            case appStoreURL = "app_store_url"
        }

        /// I testi nella lingua scelta in-app, con ripiego sui campi in cima al JSON.
        ///
        /// Il ripiego è per campo e non per blocco: una traduzione che porta solo il titolo
        /// prende comunque il resto dall'inglese, invece di far sparire tutto il resto.
        ///
        /// Si prova prima il codice pieno e poi la sola lingua, così `pt-BR` in `translations`
        /// serve un utente `pt` e viceversa — senza obbligare chi scrive il JSON a indovinare
        /// quale delle due forme userà l'app.
        func copy(for language: String) -> UpdateCopy {
            let base = UpdateCopy(title: title, message: message, releaseNotes: releaseNotes)
            guard let translations, !language.isEmpty else { return base }

            let root = language.split(separator: "-").first.map(String.init) ?? language
            let scelta = translations[language]
                ?? translations[root]
                ?? translations.first(where: { $0.key.split(separator: "-").first.map(String.init) == root })?.value
            guard let scelta else { return base }

            return UpdateCopy(
                title: scelta.title ?? base.title,
                message: scelta.message ?? base.message,
                releaseNotes: scelta.releaseNotes ?? base.releaseNotes
            )
        }
    }

    func checkForRequiredUpdate() async -> UpdateRequirement? {
        guard let configURL = URL(string: Config.updateConfigURL), !Config.updateConfigURL.isEmpty else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: configURL)
            let config = try JSONDecoder().decode(UpdateConfig.self, from: data)
            guard isUpdateRequired(minimumVersion: config.minimumVersion) else {
                return nil
            }

            let appStoreURL = config.appStoreURL ?? Config.appStoreURL
            guard !appStoreURL.isEmpty else { return nil }

            // Titolo, messaggio e note arrivano dal JSON e NON passano da `.localized`: senza
            // questo blocco la pagina era per metà nella lingua dell'utente (la cornice, che è
            // localizzata) e per metà in quella in cui era stato scritto il file.
            let testi = config.copy(for: LocalizationManager.shared.currentLanguage.id)

            return UpdateRequirement(
                minimumVersion: config.minimumVersion,
                latestVersion: config.latestVersion,
                title: testi.title ?? "update.fallbackTitle".localized,
                message: testi.message,
                releaseNotes: testi.releaseNotes ?? [],
                appStoreURL: appStoreURL
            )
        } catch {
            Logger.warning("[UpdateCheckService] Failed to fetch update config: \(error)")
            return nil
        }
    }

    private func isUpdateRequired(minimumVersion: String) -> Bool {
        guard let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
              let minimum = AppVersion(minimumVersion) else {
            return false
        }
        return current < minimum
    }
}

private struct AppVersion: Comparable {
    private let components: [Int]

    init?(_ value: String?) {
        guard let value, !value.isEmpty else { return nil }
        components = value.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
