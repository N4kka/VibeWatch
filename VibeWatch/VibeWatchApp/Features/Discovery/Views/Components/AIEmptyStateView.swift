import SwiftUI

/// Stato vuoto della chat Vibe AI: icona, titolo, sottotitolo e starter prompts "INIZIA DA QUI".
struct AIEmptyStateView: View {
    let onStarterTap: (String) -> Void

    private struct Starter: Identifiable {
        let id: Int
        let icon: String
        let titleKey: String
        let subtitleKey: String
    }

    private let starters: [Starter] = [
        Starter(id: 1, icon: "moon.stars.fill", titleKey: "ai.starter.1.title", subtitleKey: "ai.starter.1.subtitle"),
        Starter(id: 2, icon: "snowflake", titleKey: "ai.starter.2.title", subtitleKey: "ai.starter.2.subtitle"),
        Starter(id: 3, icon: "bolt.fill", titleKey: "ai.starter.3.title", subtitleKey: "ai.starter.3.subtitle"),
        Starter(id: 4, icon: "sparkles", titleKey: "ai.starter.4.title", subtitleKey: "ai.starter.4.subtitle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.theme.accentOrange.opacity(0.35), Color(hex: "e858c8").opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color.theme.accentOrange)
                )
                .padding(.top, 32)

            Text("ai.empty.title".localized)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 22)

            Text("ai.empty.subtitle".localized)
                .font(.system(size: 16))
                .foregroundStyle(Color.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 12) {
                Text("ai.empty.startHere".localized)
                    .font(.system(size: 13, weight: .bold))
                    .kerning(2)
                    .foregroundStyle(Color.theme.textSecondary)
                    .padding(.leading, 4)

                ForEach(starters) { starter in
                    Button {
                        onStarterTap(starter.titleKey.localized)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: starter.icon)
                                .font(.system(size: 17))
                                .foregroundStyle(Color.theme.accentOrange)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(starter.titleKey.localized)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.theme.textPrimary)
                                    .lineLimit(1)
                                Text(starter.subtitleKey.localized)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.theme.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.theme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
        }
    }
}
