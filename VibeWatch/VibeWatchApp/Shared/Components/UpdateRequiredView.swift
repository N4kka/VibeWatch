import SwiftUI

struct UpdateRequiredView: View {
    let requirement: UpdateRequirement

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color.theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Text(requirement.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)

                    if let message = requirement.message, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }

                if !requirement.releaseNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What's new")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(requirement.releaseNotes, id: \.self) { note in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.theme.accentOrange)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 6)
                                    Text(note)
                                        .font(.system(size: 15))
                                        .foregroundColor(.white.opacity(0.85))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }

                Button(action: openAppStore) {
                    Text("Update now")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.theme.accentOrange)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 28)
            }
        }
        .interactiveDismissDisabled(true)
    }

    private func openAppStore() {
        guard let url = URL(string: requirement.appStoreURL) else { return }
        UIApplication.shared.open(url)
    }
}
