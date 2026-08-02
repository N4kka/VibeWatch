import Foundation
import os

struct Config {
    // Secrets are sourced from Info.plist (backed by Secrets.xcconfig).
    static let tmdbAPIKey = string(for: "TMDB_API_KEY")
    static let supabaseURL = string(for: "SUPABASE_URL")
    static let supabaseAnonKey = string(for: "SUPABASE_ANON_KEY")
    static let revenueCatAPIKey = string(for: "REVENUECAT_API_KEY")
    static let posthogApiKey = string(for: "POSTHOG_API_KEY")
    static let posthogHost = string(for: "POSTHOG_HOST")
    static let updateConfigURL = string(for: "UPDATE_CONFIG_URL")
    static let appStoreURL = string(for: "APP_STORE_URL")
    // YOUTUBE_API_KEY no longer ships in the bundle either: YouTube goes through the
    // `youtube-search` Edge Function, which holds the key server-side (audit DEP-004).
    // RAPIDAPI_KEY no longer ships in the bundle: streaming availability goes through the
    // `watch-providers` Edge Function, which holds the key server-side (audit DEP-005).
}

// MARK: - Validazione all'avvio

extension Config {

    /// Cosa può esserci di storto in una chiave di configurazione.
    enum Problem: Equatable, CustomStringConvertible {
        /// La chiave manca dall'Info.plist, o c'è ma è vuota.
        case missing(key: String)
        /// La chiave c'è ma non è un URL utilizzabile dopo la normalizzazione.
        case malformedURL(key: String, value: String)

        var description: String {
            switch self {
            case .missing(let key):
                return "\(key): mancante o vuota"
            case .malformedURL(let key, let value):
                return "\(key): non è un URL https valido (\"\(value)\")"
            }
        }
    }

    /// Una chiave da controllare: nome, valore risolto, e se debba essere un URL.
    struct Entry {
        let key: String
        let value: String
        let isURL: Bool

        init(_ key: String, _ value: String, isURL: Bool = false) {
            self.key = key
            self.value = value
            self.isURL = isURL
        }
    }

    /// Tutto ciò che serve perché l'app funzioni. `RAPIDAPI_KEY` e `YOUTUBE_API_KEY` non sono qui
    /// di proposito: non spediscono più nel bundle, stanno dietro a due Edge Function.
    static var entries: [Entry] {
        [
            Entry("TMDB_API_KEY", tmdbAPIKey),
            Entry("SUPABASE_URL", supabaseURL, isURL: true),
            Entry("SUPABASE_ANON_KEY", supabaseAnonKey),
            Entry("REVENUECAT_API_KEY", revenueCatAPIKey),
            Entry("POSTHOG_API_KEY", posthogApiKey),
            Entry("POSTHOG_HOST", posthogHost, isURL: true),
            Entry("UPDATE_CONFIG_URL", updateConfigURL, isURL: true),
            Entry("APP_STORE_URL", appStoreURL, isURL: true)
        ]
    }

    /// Funzione pura: separata da `entries` per poterla esercitare con valori inventati, senza
    /// dipendere dall'Info.plist del bundle di test.
    static func problems(in entries: [Entry]) -> [Problem] {
        entries.compactMap { entry in
            guard !entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missing(key: entry.key)
            }
            guard entry.isURL else { return nil }

            // `https:` da solo passerebbe qualunque controllo basato sul prefisso: era esattamente
            // il valore che arrivava nel bundle quando `SUPABASE_URL` veniva troncata dal parser di
            // xcconfig. Serve un host, non solo uno schema.
            guard let components = URLComponents(string: entry.value),
                  components.scheme == "https",
                  let host = components.host, !host.isEmpty else {
                return .malformedURL(key: entry.key, value: entry.value)
            }
            return nil
        }
    }

    /// L'errore che i problemi di configurazione diventano quando vanno a Crashlytics come
    /// non-fatal. Un tipo suo, così nella dashboard si raggruppano da soli invece di sparire
    /// dentro un `NSError` generico.
    struct LaunchConfigurationError: LocalizedError {
        let problems: [Problem]
        var errorDescription: String? {
            "Configurazione incompleta: \(problems.map(\.description).joined(separator: "; "))"
        }
    }

    /// L'esito dell'ultima `validateAtLaunch`, conservato per chi può fare il non-fatal solo più
    /// tardi: Crashlytics non esiste prima di `FirebaseApp.configure()`, che gira in AppDelegate —
    /// DOPO l'`init()` dell'app dove la validazione deve stare. Rivalidare là sarebbe la copia
    /// che diverge; si valida una volta e si conserva l'esito.
    private(set) static var launchProblems: [Problem] = []

    /// `os.Logger`, non il `Logger` del progetto: quello è interamente dentro `#if DEBUG` e in
    /// Release non stampa una riga — era esattamente il debito ("Config muto in Release").
    /// Stesso sottosistema della sonda di §13.6; i problemi sono nomi di chiavi, mai valori,
    /// quindi `privacy: .public` non espone niente.
    private static let releaseLog = os.Logger(subsystem: "com.vibewatch.app", category: "Config")

    /// Controlla la configurazione reale del bundle.
    ///
    /// Va chiamata per prima cosa all'avvio. `Config.string(for:)` risolve una chiave mancante in
    /// stringa vuota, e da lì il guasto non assomiglia più a un errore di configurazione: TMDB
    /// risponde 401 e la schermata Scopri resta bianca. Un `SUPABASE_URL` troncato a `https:` fa
    /// fallire ogni chiamata al backend allo stesso modo silenzioso.
    @discardableResult
    static func validateAtLaunch() -> [Problem] {
        let found = problems(in: entries)
        launchProblems = found
        guard !found.isEmpty else { return [] }

        Logger.error("[Config] Configurazione incompleta — \(found.count) problemi:")
        for problem in found {
            Logger.error("[Config]   • \(problem)")
        }
        Logger.error("[Config] I valori arrivano da VibeWatchApp/Config/Secrets.xcconfig (gitignored).")

        // La traccia che sopravvive in Release: Console.app col filtro sul sottosistema
        // `com.vibewatch.app`, categoria `Config`. `.fault` e non `.error`: è il livello che il
        // sistema persiste sempre, e un'app spedita senza chiavi È un guasto, non un dettaglio.
        releaseLog.fault("Configurazione incompleta (\(found.count, privacy: .public) problemi): \(found.map(\.description).joined(separator: "; "), privacy: .public)")

        // In DEBUG si ferma qui e ora: e' il momento in cui costa meno accorgersene. In Release
        // non si fa crashare nessuno — restano il log qui sopra e il non-fatal che AppDelegate
        // manda a Crashlytics dopo `FirebaseApp.configure()` (`reportLaunchProblemsIfAny`).
        assertionFailure("Configurazione incompleta: \(found.map(\.description).joined(separator: "; "))")
        return found
    }

    /// Il secondo tempo di `validateAtLaunch`: il non-fatal a Crashlytics. Va chiamato dopo
    /// `CrashReportingService.start` — prima di `FirebaseApp.configure()` Crashlytics solleva
    /// un'eccezione, ed è il motivo per cui questo non sta dentro la validazione.
    static func reportLaunchProblemsIfAny() {
        reportLaunchProblems(launchProblems) { error, context in
            CrashReportingService.record(error, context: context)
        }
    }

    /// Pure reporting seam used by the post-Firebase launch hook. One launch produces one typed
    /// non-fatal containing every missing/malformed key, and a healthy launch produces nothing.
    @discardableResult
    static func reportLaunchProblems(
        _ problems: [Problem],
        using record: (Error, String) -> Void
    ) -> Bool {
        guard !problems.isEmpty else { return false }
        record(LaunchConfigurationError(problems: problems), "Config.validateAtLaunch")
        return true
    }
}

private extension Config {
    static func string(for key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        var normalized = raw.replacingOccurrences(of: "\\/", with: "/")
        if normalized.hasPrefix("https:/") && !normalized.hasPrefix("https://") {
            normalized = normalized.replacingOccurrences(of: "https:/", with: "https://")
        }
        if normalized.hasPrefix("http:/") && !normalized.hasPrefix("http://") {
            normalized = normalized.replacingOccurrences(of: "http:/", with: "http://")
        }
        return normalized
    }
}
