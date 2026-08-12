import SwiftUI
import UIKit

/// Window that lets every touch through to the app below, except the ones landing on real content.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return rootViewController?.view === hit ? nil : hit
    }
}

/// Lazily mounts the toast overlay on its own window, above sheets and full screen covers.
@MainActor
enum ToastWindowMounter {
    private static var window: PassthroughWindow?

    static func mountIfNeeded() {
        guard window == nil else { return }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }

        let host = UIHostingController(
            rootView: ToastOverlayView().environmentObject(ToastCenter.shared)
        )
        host.view.backgroundColor = .clear

        let overlay = PassthroughWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        overlay.rootViewController = host
        overlay.isHidden = false

        window = overlay
    }
}
