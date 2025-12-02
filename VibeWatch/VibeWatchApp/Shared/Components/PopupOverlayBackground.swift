import SwiftUI

struct PopupOverlayBackground: View {
    let onTap: () -> Void
    
    var body: some View {
        Color.black.opacity(0.4)
            .ignoresSafeArea()
            .onTapGesture(perform: onTap)
    }
}

extension View {
    @ViewBuilder
    func popupOverlayBackground(onTap: @escaping () -> Void) -> some View {
        PopupOverlayBackground(onTap: onTap)
    }
}
