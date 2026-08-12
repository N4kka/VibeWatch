import SwiftUI

/// Redesign 2.0 — l'intestazione delle schermate a tab: titolo grande e ruolo dichiarato.
///
/// Il sottotitolo non è un ornamento: Tracking e Liste convivono, e la differenza fra "cosa
/// guardi adesso" e "il tuo archivio" è la decisione di prodotto che li tiene separati. Sta
/// scritta qui, sotto il titolo, dove chi apre la schermata la legge.
struct ScreenTitleHeader: View {
    let title: String
    let subtitle: String
    /// Icona SF Symbol del bottone circolare a destra; nascosto se `nil`.
    var trailingIcon: String? = nil
    var onTrailingTap: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundColor(.theme.textSecondary)
            }

            Spacer()

            if let icon = trailingIcon {
                Button(action: onTrailingTap) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}
