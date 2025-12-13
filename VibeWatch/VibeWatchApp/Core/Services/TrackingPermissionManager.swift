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
        switch status {
        case .authorized:
            AnalyticsService.shared.setEnabled(true)
        default:
            AnalyticsService.shared.setEnabled(false)
        }
    }
}
