import SwiftUI

/// Redesign 2.0 — Scopri e Clip sono la stessa area, con uno switcher al posto di due tab.
///
/// La decisione sta nel prototipo Claude Design ("Decisioni chiave"): fondere le due superfici
/// libera uno slot nella barra, che resta a 4 tab con Social come quinta area. Lo switcher è
/// l'unico posto da cui si cambia modalità: un segmented control locale, non un tab nascosto.
enum DiscoverMode: String {
    case discover
    case clips
}

struct DiscoverModeSwitcher: View {
    @Binding var mode: DiscoverMode

    var body: some View {
        HStack(spacing: 0) {
            segment(.discover, title: "tab.discovery".localized)
            segment(.clips, title: "tab.clips".localized)
        }
        .padding(3)
        .background(Color.white.opacity(0.07))
        .overlay(
            Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
        .clipShape(Capsule())
    }

    private func segment(_ target: DiscoverMode, title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { mode = target }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                // Il testo selezionato è scuro su arancio: è la stessa inversione del FAB e dei
                // bottoni primari — l'arancio è luce funzionale, non decorazione.
                .foregroundColor(mode == target ? Color.theme.background : .theme.textSecondary)
                .padding(.horizontal, 26)
                .padding(.vertical, 8)
                .background {
                    if mode == target {
                        Capsule().fill(
                            LinearGradient(
                                colors: [Color.theme.accentOrange, Color(hex: "e56a20")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
        }
        .buttonStyle(PlainButtonStyle())
    }
}
