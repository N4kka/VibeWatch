import SwiftUI

/// Pollice su/giù + "Altri" sotto un blocco di raccomandazioni.
struct AIFeedbackRow: View {
    let feedback: Bool?
    let onThumbUp: () -> Void
    let onThumbDown: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            thumbButton(systemName: "hand.thumbsup", isActive: feedback == true, action: onThumbUp)
            thumbButton(systemName: "hand.thumbsdown", isActive: feedback == false, action: onThumbDown)

            Button(action: onMore) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                    Text("ai.more".localized)
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(Color.theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    private func thumbButton(systemName: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isActive ? systemName + ".fill" : systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? Color.theme.accentOrange : Color.theme.textPrimary)
                .frame(width: 40, height: 38)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
