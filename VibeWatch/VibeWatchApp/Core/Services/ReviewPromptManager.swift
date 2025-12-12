import Foundation
import StoreKit
import UIKit

@MainActor
final class ReviewPromptManager {
    static let shared = ReviewPromptManager()
    
    private enum Keys {
        static let launchCount = "reviewPrompt.launchCount"
        static let positiveActionCount = "reviewPrompt.positiveActionCount"
        static let lastPromptDate = "reviewPrompt.lastPromptDate"
        static let lastPromptVersion = "reviewPrompt.lastPromptVersion"
    }
    
    private let userDefaults: UserDefaults
    private let minimumLaunchCount = 3
    private let minimumPositiveActions = 1
    private let cooldownDays: TimeInterval = 120 * 24 * 60 * 60
    private var hasRegisteredThisSession = false
    
    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
    
    func registerAppLaunch() {
        guard !hasRegisteredThisSession else { return }
        hasRegisteredThisSession = true
        
        let launches = userDefaults.integer(forKey: Keys.launchCount)
        userDefaults.set(launches + 1, forKey: Keys.launchCount)
    }
    
    func recordPositiveAction(scene: UIWindowScene? = nil) {
        let actions = userDefaults.integer(forKey: Keys.positiveActionCount)
        userDefaults.set(actions + 1, forKey: Keys.positiveActionCount)
        maybePrompt(scene: scene)
    }
    
    private func maybePrompt(scene: UIWindowScene?) {
        guard userDefaults.integer(forKey: Keys.launchCount) >= minimumLaunchCount else { return }
        guard userDefaults.integer(forKey: Keys.positiveActionCount) >= minimumPositiveActions else { return }
        
        if let lastPromptDate = userDefaults.object(forKey: Keys.lastPromptDate) as? Date {
            let timeSinceLastPrompt = Date().timeIntervalSince(lastPromptDate)
            if timeSinceLastPrompt < cooldownDays {
                return
            }
        }
        
        if let lastVersion = userDefaults.string(forKey: Keys.lastPromptVersion),
           lastVersion == currentAppVersion {
            return
        }
        
        requestReview(using: scene)
        
        userDefaults.set(Date(), forKey: Keys.lastPromptDate)
        userDefaults.set(currentAppVersion, forKey: Keys.lastPromptVersion)
    }
    
    private func requestReview(using scene: UIWindowScene?) {
        if let scene {
            AppStore.requestReview(in: scene)
            return
        }
        
        if let activeScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            AppStore.requestReview(in: activeScene)
            return
        }
    }
    
    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
