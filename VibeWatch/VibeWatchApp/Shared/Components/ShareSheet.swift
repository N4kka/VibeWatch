import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        Self.recordShareOnCompletion(of: controller)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static func recordShareOnCompletion(of controller: UIActivityViewController) {
        controller.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else { return }
            Task { await GamificationService.shared.recordShare() }
        }
    }
}
