import SwiftUI

/// Floating XP badge that appears in DiscoveryView
/// - Default position: Top-right, below navigation bar
/// - Long press to move, drags to reposition
/// - Tap to expand mini dashboard
struct FloatingXPBadgeView: View {
    @ObservedObject var gamificationService: GamificationService
    @State private var isExpanded = false
    @State private var pulseAnimation = false
    @State private var showXPGain = false
    @State private var lastXPGain: Int = 0

    // Draggable position state
    @AppStorage("floatingBadgeX") private var savedX: Double = -1
    @AppStorage("floatingBadgeY") private var savedY: Double = -1
    @State private var currentPosition: CGPoint = .zero
    @State private var isDragging = false
    @State private var dragOffset: CGSize = .zero

    // Screen bounds
    @State private var screenSize: CGSize = .zero

    private let badgeSize: CGSize = CGSize(width: 70, height: 60)
    private let edgePadding: CGFloat = 16
    private let topSafeArea: CGFloat = 100 // Below nav bar
    private let bottomSafeArea: CGFloat = 100 // Above tab bar

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // Main badge
                badgeContent
                    .position(effectivePosition(in: geometry))
                    .gesture(dragGesture(in: geometry))
                    .onAppear {
                        screenSize = geometry.size
                        initializePosition(in: geometry)
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        screenSize = newSize
                        constrainPosition(in: geometry)
                    }
            }
        }
        .sheet(isPresented: $isExpanded) {
            XPMiniDashboardView(gamificationService: gamificationService, isPresented: $isExpanded)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        .onChange(of: gamificationService.recentXPEvent?.id) { _, newId in
            if newId != nil, let event = gamificationService.recentXPEvent {
                triggerXPGainAnimation(amount: event.totalXP)
            }
        }
    }

    private var badgeContent: some View {
        ZStack(alignment: .topTrailing) {
            // Main badge
            collapsedBadge
                .onTapGesture {
                    if !isDragging {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    }
                }

            // XP gain indicator
            if showXPGain {
                XPGainBubble(amount: lastXPGain)
                    .offset(x: 10, y: -25)
                    .transition(.asymmetric(
                        insertion: .scale.combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .scaleEffect(isDragging ? 1.1 : 1.0)
        .shadow(color: isDragging ? .theme.accentOrange.opacity(0.5) : .clear, radius: 15, x: 0, y: 5)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
    }

    private var collapsedBadge: some View {
        VStack(spacing: 2) {
            // Level
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.yellow)
                Text(String(format: "gamification.levelShort".localized, gamificationService.userState.currentLevel))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }

            // Streak
            if gamificationService.userState.currentStreak > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text("\(gamificationService.userState.currentStreak)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.theme.backgroundDark.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: isDragging ?
                                    [.theme.accentOrange, .purple] :
                                    [.theme.accentOrange.opacity(0.6), .purple.opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isDragging ? 3 : 2
                        )
                )
                .shadow(color: .theme.accentOrange.opacity(pulseAnimation ? 0.5 : 0.2), radius: pulseAnimation ? 15 : 8, x: 0, y: 4)
        )
        .scaleEffect(pulseAnimation ? 1.05 : 1.0)
    }

    // MARK: - Position Management

    private func initializePosition(in geometry: GeometryProxy) {
        if savedX < 0 || savedY < 0 {
            // Default: top-right, below navigation bar
            currentPosition = CGPoint(
                x: geometry.size.width - badgeSize.width / 2 - edgePadding,
                y: topSafeArea + badgeSize.height / 2
            )
            savePosition()
        } else {
            currentPosition = CGPoint(x: savedX, y: savedY)
            constrainPosition(in: geometry)
        }
    }

    private func effectivePosition(in geometry: GeometryProxy) -> CGPoint {
        if isDragging {
            return CGPoint(
                x: currentPosition.x + dragOffset.width,
                y: currentPosition.y + dragOffset.height
            )
        }
        return currentPosition
    }

    private func constrainPosition(in geometry: GeometryProxy) {
        let minX = badgeSize.width / 2 + edgePadding
        let maxX = geometry.size.width - badgeSize.width / 2 - edgePadding
        let minY = topSafeArea + badgeSize.height / 2
        let maxY = geometry.size.height - bottomSafeArea - badgeSize.height / 2

        currentPosition.x = min(max(currentPosition.x, minX), maxX)
        currentPosition.y = min(max(currentPosition.y, minY), maxY)
    }

    private func snapToEdge(in geometry: GeometryProxy) {
        let centerX = geometry.size.width / 2

        // Snap to left or right edge based on position
        if currentPosition.x < centerX {
            currentPosition.x = badgeSize.width / 2 + edgePadding
        } else {
            currentPosition.x = geometry.size.width - badgeSize.width / 2 - edgePadding
        }

        constrainPosition(in: geometry)
        savePosition()
    }

    private func savePosition() {
        savedX = currentPosition.x
        savedY = currentPosition.y
    }

    // MARK: - Gestures

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                // Enter drag mode
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isDragging = true
                }
            }
            .sequenced(before: DragGesture())
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    if let drag = drag {
                        dragOffset = drag.translation
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                switch value {
                case .second(true, let drag):
                    if let drag = drag {
                        currentPosition.x += drag.translation.width
                        currentPosition.y += drag.translation.height
                    }
                    dragOffset = .zero

                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        isDragging = false
                        snapToEdge(in: geometry)
                    }

                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                default:
                    isDragging = false
                    dragOffset = .zero
                }
            }
    }

    // MARK: - Animations

    private func triggerXPGainAnimation(amount: Int) {
        lastXPGain = amount

        // Pulse animation
        withAnimation(.easeInOut(duration: 0.3)) {
            pulseAnimation = true
        }

        withAnimation(.easeInOut(duration: 0.3).delay(0.3)) {
            pulseAnimation = false
        }

        // XP bubble
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showXPGain = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showXPGain = false
            }
        }
    }
}

// MARK: - XP Gain Bubble

struct XPGainBubble: View {
    let amount: Int
    @State private var offset: CGFloat = 0

    var body: some View {
        Text("+\(amount)")
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.theme.accentOrange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.theme.accentOrange.opacity(0.2))
            )
            .offset(y: offset)
            .onAppear {
                withAnimation(.easeOut(duration: 1.0)) {
                    offset = -20
                }
            }
    }
}

// MARK: - Mini Dashboard (Bottom Sheet)

struct XPMiniDashboardView: View {
    @ObservedObject var gamificationService: GamificationService
    @Binding var isPresented: Bool
    @State private var navigateToFullStats = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Level & XP Progress
                    levelProgressCard

                    // Streak Card
                    streakCard

                    // Daily Challenge
                    dailyChallengeCard

                    // Recent Badge
                    if let recentBadge = gamificationService.getRecentlyUnlockedBadge() {
                        recentBadgeCard(badge: recentBadge)
                    }

                    // View Full Stats Button
                    NavigationLink(destination: AnalyticsDashboardView()) {
                        HStack {
                            Text("stats.viewFull".localized)
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14))
                        }
                        .foregroundColor(.theme.accentOrange)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.theme.accentOrange.opacity(0.1))
                        )
                    }
                }
                .padding()
            }
            .background(Color.theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("gamification.progress.title".localized)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Level Progress Card

    private var levelProgressCard: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.yellow)

                        Text(String(format: "gamification.levelNumber".localized, gamificationService.userState.currentLevel))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Text(gamificationService.userState.rank.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(gamificationService.userState.rank.color)
                }

                Spacer()
            }

            // XP Progress Bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 12)

                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [.theme.accentOrange, .orange],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * gamificationService.userState.levelProgress, height: 12)
                    }
                }
                .frame(height: 12)

                HStack {
                    Text("\(gamificationService.userState.totalXP) XP")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(gamificationService.userState.xpForNextLevel) XP")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Streak Card

    private var streakCard: some View {
        HStack(spacing: 16) {
            VStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.orange)

                Text("\(gamificationService.userState.currentStreak)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)

                Text("gamification.dayStreak".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 60)
                .background(Color.white.opacity(0.2))

            VStack(spacing: 4) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.yellow)

                Text("\(gamificationService.userState.longestStreak)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)

                Text("gamification.bestStreak".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)

            if gamificationService.userState.streakBonusPercentage > 0 {
                Divider()
                    .frame(height: 60)
                    .background(Color.white.opacity(0.2))

                VStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.theme.accentOrange)

                    Text("+\(gamificationService.userState.streakBonusPercentage)%")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.theme.accentOrange)

                    Text("gamification.xpBonus".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Daily Challenge Card

    private var dailyChallengeCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.green)

                Text("gamification.todaysChallenge".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if let challenge = gamificationService.currentChallenge {
                    Text("+\(challenge.type.xpReward) XP")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.theme.accentOrange)
                }
            }

            if let challenge = gamificationService.currentChallenge {
                VStack(spacing: 8) {
                    HStack {
                        Text(challenge.type.description)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))

                        Spacer()

                        Text("\(challenge.progress)/\(challenge.type.target)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(challenge.completed ? .green : .white)
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 8)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(challenge.completed ? Color.green : Color.theme.accentOrange)
                                .frame(width: geometry.size.width * min(1.0, Double(challenge.progress) / Double(challenge.type.target)), height: 8)
                        }
                    }
                    .frame(height: 8)
                }

                if challenge.completed {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("gamification.completed".localized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Recent Badge Card

    private func recentBadgeCard(badge: BadgeDefinition) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(badge.color.opacity(0.2))
                    .frame(width: 56, height: 56)

                Image(systemName: badge.icon)
                    .font(.system(size: 28))
                    .foregroundColor(badge.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("gamification.badgeUnlocked".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.yellow)

                Text(badge.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)

                Text(badge.description)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [badge.color.opacity(0.15), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(badge.color.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Pro Badge View

struct ProBadgeView: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12))
            Text("x2")
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundColor(.theme.accentOrange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.theme.accentOrange.opacity(0.2))
        )
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.theme.background.ignoresSafeArea()

        FloatingXPBadgeView(gamificationService: GamificationService.shared)
    }
}
