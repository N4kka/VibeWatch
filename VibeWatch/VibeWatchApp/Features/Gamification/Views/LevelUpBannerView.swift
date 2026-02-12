import SwiftUI

/// Celebratory banner shown when user levels up
struct LevelUpBannerView: View {
    let oldLevel: Int
    let newLevel: Int
    let newRank: UserRank
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var offset: CGFloat = -150

    var body: some View {
        VStack {
            if isVisible {
                bannerContent
                    .offset(y: offset)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()
        }
        .onAppear {
            showBanner()
        }
    }

    private var bannerContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Level Badge
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [newRank.color, newRank.color.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)

                    Text("\(newLevel)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("gamification.levelUp".localized)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(.white.opacity(0.9))
                            .tracking(1)

                        Text("🎉")
                            .font(.system(size: 16))
                    }

                    HStack(spacing: 4) {
                        Text("\("gamification.level".localized) \(oldLevel)")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.6))

                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))

                        Text("\("gamification.level".localized) \(newLevel)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Text(String(format: "gamification.rankAchieved".localized, newRank.name))
                        .font(.system(size: 13))
                        .foregroundColor(newRank.color)
                }

                Spacer()

                // Dismiss Button
                Button {
                    dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [
                            newRank.color.opacity(0.9),
                            newRank.color.opacity(0.7),
                            Color.theme.backgroundDark.opacity(0.95)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(newRank.color.opacity(0.5), lineWidth: 1)
                )
                .shadow(color: newRank.color.opacity(0.4), radius: 20, x: 0, y: 10)
        )
        .padding(.horizontal, 16)
        .padding(.top, 60) // Below status bar
    }

    private func showBanner() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            isVisible = true
            offset = 0
        }

        // Auto-dismiss after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            dismissBanner()
        }
    }

    private func dismissBanner() {
        withAnimation(.easeOut(duration: 0.3)) {
            offset = -150
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}

// MARK: - Level Up Banner Modifier

struct LevelUpBannerModifier: ViewModifier {
    @ObservedObject var gamificationService: GamificationService
    @State private var levelUpEvent: LevelUpEvent?

    func body(content: Content) -> some View {
        ZStack {
            content

            if let event = levelUpEvent {
                LevelUpBannerView(
                    oldLevel: event.oldLevel,
                    newLevel: event.newLevel,
                    newRank: event.newRank
                ) {
                    levelUpEvent = nil
                }
                .zIndex(2000)
            }
        }
        .onChange(of: gamificationService.recentLevelUp?.id) { _, newId in
            if newId != nil, let event = gamificationService.recentLevelUp {
                // Small delay to allow previous banner to dismiss
                if levelUpEvent != nil {
                    levelUpEvent = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        levelUpEvent = event
                    }
                } else {
                    levelUpEvent = event
                }
            }
        }
    }
}

extension View {
    func levelUpBanner(gamificationService: GamificationService) -> some View {
        modifier(LevelUpBannerModifier(gamificationService: gamificationService))
    }
}

// MARK: - Level Up Event

struct LevelUpEvent: Identifiable, Equatable {
    let id = UUID()
    let oldLevel: Int
    let newLevel: Int
    let newRank: UserRank
    let timestamp: Date

    static func == (lhs: LevelUpEvent, rhs: LevelUpEvent) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.theme.background.ignoresSafeArea()

        LevelUpBannerView(
            oldLevel: 4,
            newLevel: 5,
            newRank: UserRank.forLevel(5),
            onDismiss: {}
        )
    }
}
