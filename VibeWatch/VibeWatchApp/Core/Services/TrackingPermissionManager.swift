import Foundation
import AppTrackingTransparency

@MainActor
final class TrackingPermissionManager: ObservableObject {
    static let shared = TrackingPermissionManager()
    
    private let hasPromptedKey = "trackingPermission.hasPrompted"
    private var hasPrompted: Bool {
        get { UserDefaults.standard.bool(forKey: hasPromptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasPromptedKey) }
    }
    
    func requestTrackingIfNeeded() async {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            await updateAnalyticsState(for: ATTrackingManager.trackingAuthorizationStatus)
            return
        }
        
        guard !hasPrompted else { return }
        hasPrompted = true
        
        let status = await ATTrackingManager.requestTrackingAuthorization()
        await updateAnalyticsState(for: status)
    }
    
    private func updateAnalyticsState(for status: ATTrackingManager.AuthorizationStatus) async {
        // ATT is for cross-app tracking/IDFA; product analytics should not depend on it.
        // Keep this hook for future ad attribution, but do not gate AnalyticsService here.
        UserDefaults.standard.set(status.rawValue, forKey: "trackingPermission.status")
    }
}
