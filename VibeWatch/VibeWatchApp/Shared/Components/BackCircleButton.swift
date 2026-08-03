import SwiftUI

/// Redesign 2.0 — la porta d'uscita standard delle sottopagine.
/// L'area tappabile resta circolare, ma il controllo non disegna alcun fill dietro al chevron.
struct BackCircleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("common.close".localized))
    }
}
