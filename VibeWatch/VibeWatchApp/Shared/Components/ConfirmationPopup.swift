import SwiftUI

struct ConfirmationPopup: View {
    let title: String
    let message: String?
    let confirmTitle: String
    let cancelTitle: String
    var isDestructive: Bool = false
    var onConfirm: () -> Void
    var onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
            
            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text(cancelTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                
                Button(action: onConfirm) {
                    Text(confirmTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(isDestructive ? Color.red : Color.theme.accentOrange)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.theme.backgroundDark.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08))
                )
                .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 10)
        )
        .padding(.horizontal, 24)
    }
}
