import SwiftUI

/// Header della pagina Vibe AI: chiudi, titolo gradient + badge quota, sottotitolo con il titolo
/// della chat corrente, bottoni nuova chat e cronologia.
struct AIChatHeader: View {
    let requestsUsedToday: Int
    let dailyRequestLimit: Int
    let chatTitle: String?
    let onClose: () -> Void
    let onNewChat: () -> Void
    let onShowHistory: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            roundButton(systemName: "chevron.down", action: onClose)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("ai.title".localized)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                // Il magenta del prototipo 2.0 (#e858c8), non il purple di sistema.
                                colors: [Color.theme.accentOrange, Color(hex: "e858c8")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text(String(format: "ai.header.usageBadge".localized, requestsUsedToday, dailyRequestLimit))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.theme.accentOrange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.theme.accentOrange.opacity(0.14))
                        .clipShape(Capsule())
                }

                if let chatTitle, !chatTitle.isEmpty {
                    Text(chatTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            roundButton(systemName: "plus", action: onNewChat)
            roundButton(systemName: "clock.arrow.circlepath", action: onShowHistory)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func roundButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.theme.textPrimary)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
