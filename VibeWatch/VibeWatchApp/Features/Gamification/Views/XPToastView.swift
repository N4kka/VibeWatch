import SwiftUI

/// Animated toast notification showing XP earned with Pro boost breakdown
struct XPToastView: View {
    let event: XPEarnedEvent
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var offset: CGFloat = -100

    var body: some View {
        VStack(spacing: 0) {
            toastContent
                .offset(y: offset)
                .opacity(isVisible ? 1 : 0)

            Spacer()
        }
        .onAppear {
            showToast()
        }
    }

    private var toastContent: some View {
        VStack(spacing: 8) {
            // Header with icon and title
            HStack(spacing: 8) {
                Image(systemName: event.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)

                Text(event.displayTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)

                Spacer()
            }

            Divider()
                .background(Color.white.opacity(0.2))

            // XP Breakdown
            VStack(spacing: 4) {
                // Base XP
                HStack {
                    Text("+\(event.baseXP) XP")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.8))
                    Text("gamification.xp.base".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                }

                // Pro Boost (if applicable)
                if event.isPro && event.proBonus > 0 {
                    HStack {
                        Text("+\(event.proBonus) XP")
                            .font(.system(size: 14))
                            .foregroundColor(.theme.accentOrange)
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                            Text("gamification.xp.proBoost".localized)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.theme.accentOrange)
                        Spacer()
                    }
                }

                // Streak Bonus (if applicable)
                if event.streakBonus > 0 {
                    HStack {
                        Text("+\(event.streakBonus) XP")
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 10))
                            Text("gamification.xp.streakBonus".localized)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.orange)
                        Spacer()
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.2))

            // Total
            HStack {
                Text("=")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                Text("\(event.totalXP) \("gamification.xp.total".localized)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }

            // Challenge Progress (if applicable)
            if let progress = event.challengeProgress {
                Divider()
                    .background(Color.white.opacity(0.2))
                    .padding(.top, 4)

                challengeProgressSection(progress)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.theme.backgroundDark.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [.theme.accentOrange.opacity(0.5), .orange.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .theme.accentOrange.opacity(0.3), radius: 20, x: 0, y: 10)
        )
        .padding(.horizontal, 20)
        .padding(.top, 60) // Below status bar
    }

    private func challengeProgressSection(_ progress: ChallengeProgressInfo) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: progress.icon)
                    .font(.system(size: 14))
                    .foregroundColor(progress.isCompleted ? .green : .white.opacity(0.7))

                Text(progress.title)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Text(progress.progressText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(progress.isCompleted ? .green : .white)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            progress.isCompleted ?
                            LinearGradient(colors: [.green, .green.opacity(0.7)], startPoint: .leading, endPoint: .trailing) :
                            LinearGradient(colors: [.theme.accentOrange, .orange], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geometry.size.width * progress.progress, height: 8)
                }
            }
            .frame(height: 8)

            if progress.isCompleted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("gamification.challengeComplete".localized)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.green)
            }
        }
        .padding(.top, 4)
    }

    private func showToast() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            isVisible = true
            offset = 0
        }

        // Auto dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            dismissToast()
        }
    }

    private func dismissToast() {
        withAnimation(.easeOut(duration: 0.3)) {
            isVisible = false
            offset = -100
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}

// MARK: - Toast Modifier

struct XPToastModifier: ViewModifier {
    @ObservedObject var gamificationService: GamificationService
    @State private var currentEvent: XPEarnedEvent?

    func body(content: Content) -> some View {
        ZStack {
            content

            if let event = currentEvent {
                XPToastView(event: event) {
                    currentEvent = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1000)
            }
        }
        .onChange(of: gamificationService.recentXPEvent?.id) { _, newId in
            if newId != nil, let event = gamificationService.recentXPEvent {
                // Small delay to allow previous toast to dismiss
                if currentEvent != nil {
                    currentEvent = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        currentEvent = event
                    }
                } else {
                    currentEvent = event
                }
            }
        }
    }
}

extension View {
    func xpToast(gamificationService: GamificationService) -> some View {
        modifier(XPToastModifier(gamificationService: gamificationService))
    }
}

// MARK: - Floating XP Indicator (Mini version for inline display)

struct XPEarnedIndicator: View {
    let xp: Int
    let isPro: Bool

    @State private var isVisible = false
    @State private var offset: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(xp)")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.theme.accentOrange)

            Text("XP")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.theme.accentOrange.opacity(0.8))

            if isPro {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.theme.accentOrange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.theme.accentOrange.opacity(0.2))
                .overlay(
                    Capsule()
                        .stroke(Color.theme.accentOrange.opacity(0.5), lineWidth: 1)
                )
        )
        .offset(y: offset)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                isVisible = true
            }

            // Float up and fade
            withAnimation(.easeOut(duration: 1.5).delay(0.5)) {
                offset = -30
            }

            withAnimation(.easeOut(duration: 0.5).delay(1.5)) {
                isVisible = false
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.theme.background.ignoresSafeArea()

        VStack {
            Spacer()
        }

        XPToastView(
            event: XPEarnedEvent(
                actionType: .clipWatched,
                baseXP: 5,
                proBonus: 5,
                streakBonus: 2,
                totalXP: 12,
                isPro: true,
                timestamp: Date()
            ),
            onDismiss: {}
        )
    }
}
