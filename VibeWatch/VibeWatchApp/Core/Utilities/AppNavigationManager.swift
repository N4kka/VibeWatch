import Foundation
import Combine
import SwiftUI

// MARK: - DeepLinkTarget

/// Represents a specific destination within the app that can be triggered by a deep link.
struct DeepLinkTarget: Identifiable, Equatable {
    let id = UUID() // For Identifiable conformance, useful for some SwiftUI modifiers
    let mediaId: Int
    let mediaType: String // "movie" or "tv"

    static func == (lhs: DeepLinkTarget, rhs: DeepLinkTarget) -> Bool {
        lhs.mediaId == rhs.mediaId && lhs.mediaType == rhs.mediaType
    }
}

// MARK: - ProfileLinkTarget

/// SPEC v3 §9.4 — la destinazione di un link `/@{username}`.
/// `id` è lo username: due link allo stesso profilo sono la stessa destinazione,
/// e `sheet(item:)` non ripresenta niente.
struct ProfileLinkTarget: Identifiable, Equatable {
    let username: String
    var id: String { username }
}

// MARK: - ActivityLinkTarget

/// Social feed M3 — la card che ha ricevuto un like o un commento.
/// `id` è l'id dell'attività: due push sulla stessa card sono la stessa destinazione.
struct ActivityLinkTarget: Identifiable, Equatable {
    let activityId: UUID
    var id: UUID { activityId }
}

// MARK: - AppNavigationManager

/// Manages deep link navigation state across the app.
/// SwiftUI views can observe this manager to react to deep link requests.
class AppNavigationManager: ObservableObject {
    @MainActor static let shared = AppNavigationManager() // Singleton instance

    /// SPEC v3 §9.4: il profilo da presentare per un universal link `/@{username}`.
    /// Lo osserva `MainTabView`, che lo presenta come sheet.
    @Published var profileLinkTarget: ProfileLinkTarget? = nil

    /// Social feed M3: la card da aprire dopo il tap su una push di like/commento.
    /// La osserva `MainTabView`, che la presenta come sheet.
    @Published var activityLinkTarget: ActivityLinkTarget? = nil

    @Published var deepLinkTarget: DeepLinkTarget? = nil {
        didSet {
            if deepLinkTarget != nil {
                Logger.debug("[AppNavigationManager] Deep link target set: \(deepLinkTarget?.mediaType ?? "") \(deepLinkTarget?.mediaId ?? 0)")
            } else {
                Logger.debug("[AppNavigationManager] Deep link target cleared.")
            }
        }
    }
    
    private init() {} // Private initializer for singleton pattern
    
    /// Processes a dictionary (e.g., from a push notification payload)
    /// and attempts to set a deep link target.
    /// - Parameter userInfo: The dictionary containing deep link information.
    func handle(userInfo: [AnyHashable: Any]) {
        Logger.debug("[AppNavigationManager] Handling userInfo for deep link: \(userInfo)")

        // Redesign 2.0 import: il tap sulla push "Import finished" porta in home CON l'inbox
        // "Titoli da verificare" già aperto (se c'è qualcosa da gestire) — prima atterrava su
        // Discovery generica e la promessa di `import.canClose` finiva nel vuoto.
        if (userInfo["notification_type"] as? String) == "import_done" {
            Logger.info("[AppNavigationManager] import_done push → home + inbox import")
            NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
            Task { @MainActor in
                ImportStatusCenter.shared.handleImportPushTap()
            }
            return
        }

        // Social feed M3: le push social non hanno un media, hanno una CARD (like, commento) o
        // nessuna destinazione precisa (il "ti segue": l'attore non viaggia nel payload). L'id
        // della card sta in `thread_id`, nella forma `social:{activity_id}` — la stessa chiave
        // con cui i trigger deduplicano, quindi non c'è un secondo campo da tenere allineato.
        if let type = userInfo["notification_type"] as? String, Self.socialTypes.contains(type) {
            if let thread = userInfo["thread_id"] as? String,
               thread.hasPrefix("social:"),
               let activityId = UUID(uuidString: String(thread.dropFirst("social:".count))) {
                Logger.info("[AppNavigationManager] push social → card \(activityId)")
                activityLinkTarget = ActivityLinkTarget(activityId: activityId)
            } else {
                // Digest, "ti segue", o una versione del server che non manda ancora il thread:
                // il tab Social è la destinazione onesta — è lì che vive tutto ciò di cui la
                // notifica parlava. Discovery (il ripiego generico) sarebbe un cambio di discorso.
                Logger.info("[AppNavigationManager] push social senza card → tab Social")
                NotificationCenter.default.post(name: .navigateToSocialTab, object: nil)
            }
            return
        }

        // --- More robust parsing to handle different possible keys ---
        let mediaIdKey = userInfo["media_id"] != nil ? "media_id" : "movie_id"
        let mediaTypeKey = userInfo["media_type"] != nil ? "media_type" : "movie_type"
        
        var parsedMediaId: Int?
        
        // Attempt to parse mediaId whether it's a String or a Number
        if let mediaIdString = userInfo[mediaIdKey] as? String {
            parsedMediaId = Int(mediaIdString)
        } else if let mediaIdNumber = userInfo[mediaIdKey] as? NSNumber {
            parsedMediaId = mediaIdNumber.intValue
        }
        
        // Ensure mediaType is a string
        guard let mediaType = userInfo[mediaTypeKey] as? String else {
            Logger.info("[AppNavigationManager] Notification has no media_type — navigating to Discovery.")
            NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
            return
        }

        // Ensure we have a valid mediaId
        guard let mediaId = parsedMediaId else {
            Logger.info("[AppNavigationManager] Notification has no media_id — navigating to Discovery.")
            NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
            return
        }

        // Ensure mediaType is valid (even if the key was movie_type, the value should be 'movie' or 'tv')
        if mediaType == "movie" || mediaType == "tv" {
            self.deepLinkTarget = DeepLinkTarget(mediaId: mediaId, mediaType: mediaType)
            Logger.debug("[AppNavigationManager] Parsed deep link to \(mediaType) ID \(mediaId)")
        } else {
            Logger.error("[AppNavigationManager] Invalid media_type value in deep link: \(mediaType)")
            NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
        }
    }

    /// SPEC v3 §9.4 — prova a instradare un universal link (`/@{username}` o `/film/{id}`).
    ///
    /// Restituisce `false` per un URL che non è una rotta nostra, **senza toccare niente**: chi
    /// chiama (l'`onOpenURL` dell'app) deve poter passare lo stesso URL al ramo OAuth. Un link
    /// non riconosciuto che navigasse "da qualche parte" sarebbe un fallimento travestito da
    /// risposta, la famiglia di difetti in testa a spec-v3-STATO.md.
    @discardableResult
    func handle(universalLink url: URL) -> Bool {
        guard let route = UniversalLinks.route(for: url) else { return false }
        switch route {
        case .profile(let username):
            Logger.info("[AppNavigationManager] Universal link → profilo @\(username)")
            Task { @MainActor in
                AnalyticsService.shared.track(.deepLinkOpened(route: "profile", source: "universal_link"))
            }
            profileLinkTarget = ProfileLinkTarget(username: username)
        case .film(let id):
            // Stessa strada delle notifiche push: `MainTabView` sa già aprire un film da qui.
            Logger.info("[AppNavigationManager] Universal link → film \(id)")
            Task { @MainActor in
                AnalyticsService.shared.track(.deepLinkOpened(route: "film", source: "universal_link"))
            }
            deepLinkTarget = DeepLinkTarget(mediaId: id, mediaType: "movie")
        }
        return true
    }

    /// I tipi che il server marca come categoria `social` (vedi SOCIAL_TYPES in
    /// process-notifications): l'elenco vive in due posti perché sono due sistemi, ma è corto
    /// e cambia insieme alle migration che aggiungono un tipo.
    private static let socialTypes: Set<String> = [
        "new_follower", "activity_liked", "activity_commented",
    ]

    /// Clears the activity link target after the sheet has been dismissed.
    func clearActivityLinkTarget() {
        self.activityLinkTarget = nil
    }

    /// Clears the profile link target after the sheet has been dismissed.
    func clearProfileLinkTarget() {
        self.profileLinkTarget = nil
    }

    /// Handles tap on notifications that have no associated media (e.g. streak reminders).
    func handleNoMediaNotification() {
        NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
    }
    
    /// Clears the current deep link target after it has been handled by the UI.
    func clearDeepLinkTarget() {
        self.deepLinkTarget = nil
    }
}
