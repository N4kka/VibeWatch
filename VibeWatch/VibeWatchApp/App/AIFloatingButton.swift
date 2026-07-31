import SwiftUI

/// SPEC v3 §9.1 `DECISO` — l'AI esce dai tab e diventa un pulsante flottante persistente.
///
/// **Perché non è una perdita di rilievo.** Un tab su quattro è la posizione più costosa che
/// un'app abbia: il tab che l'AI occupava è quello che ora ospita il Tracking, cioè la schermata
/// che un utente TV Time apre ogni giorno e che la spec vuole "a un tap". L'AI si usa quando non
/// si sa cosa guardare, il Tracking quando lo si sa già: la seconda è molto più frequente.
///
/// Il pulsante resta visibile su tutti i tab, quindi l'AI non è più lontana — è solo altrove.
struct AIFloatingButton: View {
    let action: () -> Void

    @State private var pulsing = false

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
            // Il respiro è lento e minimo di proposito: un elemento sempre a schermo che si
            // muove troppo diventa qualcosa da cui distogliere lo sguardo, non da premere.
            .scaleEffect(pulsing ? 1.04 : 1.0)
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulsing)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text("tab.ai".localized))
        .onAppear { pulsing = true }
    }
}
