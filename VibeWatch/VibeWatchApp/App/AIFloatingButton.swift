import SwiftUI

/// SPEC v3 §9.1 `DECISO` — l'AI esce dai tab e diventa un pulsante flottante persistente.
///
/// **Perché non è una perdita di rilievo.** Un tab su quattro è la posizione più costosa che
/// un'app abbia: il tab che l'AI occupava è quello che ora ospita il Tracking, cioè la schermata
/// che un utente TV Time apre ogni giorno e che la spec vuole "a un tap". L'AI si usa quando non
/// si sa cosa guardare, il Tracking quando lo si sa già: la seconda è molto più frequente.
///
/// Il pulsante resta visibile su tutti i tab, quindi l'AI non è più lontana — è solo altrove.
///
/// **Nessuna animazione, di proposito.** La prima versione aveva un "respiro" (`scaleEffect`
/// ripetuto all'infinito): dentro lo stack della tab bar quell'animazione veniva raccolta dal
/// layout e il pulsante derivava in diagonale a ogni cambio di tab. Un elemento sempre a schermo
/// che si muove non è vivo, è rotto: deve stare fermo dov'è.
struct AIFloatingButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.theme.accentOrange, Color.theme.accentOrange.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)

                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text("tab.ai".localized))
    }
}
