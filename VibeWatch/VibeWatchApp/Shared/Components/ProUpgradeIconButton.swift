import SwiftUI

struct ProUpgradeIconButton: View {
    let isProUser: Bool
    let source: String

    var body: some View {
        if isProUser {
            EmptyView()
        } else {
            Button {
                NotificationCenter.default.post(
                    name: .presentProPaywall,
                    object: nil,
                    userInfo: ["source": source]
                )
            } label: {
                Image(systemName: "crown.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.theme.accentOrange.opacity(0.9))
                    .clipShape(Circle())
                    .shadow(color: Color.theme.accentOrange.opacity(0.25), radius: 10, x: 0, y: 6)
                    .accessibilityLabel("paywall.upgrade".localized)
            }
        }
    }
}

