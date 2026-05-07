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

// MARK: - AppNavigationManager

/// Manages deep link navigation state across the app.
/// SwiftUI views can observe this manager to react to deep link requests.
class AppNavigationManager: ObservableObject {
    @MainActor static let shared = AppNavigationManager() // Singleton instance
    
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
            Logger.error("[AppNavigationManager] Deep link userInfo is missing or has invalid media type key.")
            return
        }
        
        // Ensure we have a valid mediaId
        guard let mediaId = parsedMediaId else {
            Logger.error("[AppNavigationManager] Deep link userInfo is missing or has invalid media id key.")
            return
        }

        // Ensure mediaType is valid (even if the key was movie_type, the value should be 'movie' or 'tv')
        if mediaType == "movie" || mediaType == "tv" {
            self.deepLinkTarget = DeepLinkTarget(mediaId: mediaId, mediaType: mediaType)
            Logger.debug("[AppNavigationManager] Parsed deep link to \(mediaType) ID \(mediaId)")
        } else {
            Logger.error("[AppNavigationManager] Invalid media_type value in deep link: \(mediaType)")
        }
    }
    
    /// Clears the current deep link target after it has been handled by the UI.
    func clearDeepLinkTarget() {
        self.deepLinkTarget = nil
    }
}
