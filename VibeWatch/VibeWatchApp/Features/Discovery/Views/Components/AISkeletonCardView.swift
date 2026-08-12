import SwiftUI

/// Placeholder shimmer mostrato mentre Vibe AI cerca e risolve i titoli.
struct AISkeletonCardView: View {
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 76, height: 106)

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 180, height: 14)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 120, height: 12)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
            }
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(pulse ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

/// Riga di stato + skeleton cards durante il loading della risposta AI.
struct AILoadingStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.theme.accentOrange, Color(hex: "e858c8")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 24, height: 24)
                Text("ai.searching".localized)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.theme.textSecondary)
            }

            AISkeletonCardView()
            AISkeletonCardView()
        }
    }
}
