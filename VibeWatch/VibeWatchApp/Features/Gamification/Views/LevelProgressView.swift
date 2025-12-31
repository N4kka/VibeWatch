import SwiftUI

/// View showing all levels with XP progress for each
struct LevelProgressView: View {
    @ObservedObject var gamificationService: GamificationService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        // Current Level Hero
                        currentLevelCard

                        // All Levels List
                        allLevelsSection
                    }
                    .padding()
                }
                .onAppear {
                    // Auto-scroll to current level
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation {
                            proxy.scrollTo(gamificationService.userState.currentLevel, anchor: .center)
                        }
                    }
                }
            }
            .background(Color.theme.background.ignoresSafeArea())
            .navigationTitle("Level Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
            }
        }
    }

    // MARK: - Current Level Card

    private var currentLevelCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                // Level Badge
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    gamificationService.userState.rank.color,
                                    gamificationService.userState.rank.color.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)

                    Text("\(gamificationService.userState.currentLevel)")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Level \(gamificationService.userState.currentLevel)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

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
                    Text("\(gamificationService.userState.xpProgressInLevel) / \(gamificationService.userState.xpNeededForNextLevel) XP")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(gamificationService.userState.xpNeededForNextLevel - gamificationService.userState.xpProgressInLevel) XP to next level")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(gamificationService.userState.rank.color.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - All Levels Section

    private var allLevelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ALL LEVELS")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
                .tracking(1)

            VStack(spacing: 0) {
                ForEach(1...50, id: \.self) { level in
                    LevelRowView(
                        level: level,
                        currentLevel: gamificationService.userState.currentLevel,
                        totalXP: gamificationService.userState.totalXP
                    )
                    .id(level)

                    if level < 50 {
                        Divider()
                            .background(Color.white.opacity(0.1))
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.03))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Level Row View

struct LevelRowView: View {
    let level: Int
    let currentLevel: Int
    let totalXP: Int

    private var levelInfo: (xpStart: Int, xpEnd: Int, rank: UserRank) {
        LevelCalculator.getLevelInfo(level: level)
    }

    private var isCompleted: Bool {
        level < currentLevel
    }

    private var isCurrent: Bool {
        level == currentLevel
    }

    private var isLocked: Bool {
        level > currentLevel
    }

    private var xpEarned: Int {
        if isCompleted {
            return levelInfo.xpEnd - levelInfo.xpStart
        } else if isCurrent {
            return totalXP - levelInfo.xpStart
        } else {
            return 0
        }
    }

    private var xpRequired: Int {
        levelInfo.xpEnd - levelInfo.xpStart
    }

    private var progress: Double {
        guard xpRequired > 0 else { return 0 }
        return Double(xpEarned) / Double(xpRequired)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status Icon
            ZStack {
                Circle()
                    .fill(statusBackgroundColor)
                    .frame(width: 32, height: 32)

                statusIcon
            }

            // Level Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Level \(level)")
                        .font(.system(size: 15, weight: isCurrent ? .bold : .medium))
                        .foregroundColor(isCurrent ? .white : (isLocked ? .white.opacity(0.4) : .white.opacity(0.7)))

                    Text(levelInfo.rank.name)
                        .font(.system(size: 13))
                        .foregroundColor(isCurrent ? levelInfo.rank.color : (isLocked ? .white.opacity(0.3) : levelInfo.rank.color.opacity(0.6)))
                }

                // XP Progress
                HStack(spacing: 8) {
                    // Mini progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(isCurrent ? Color.theme.accentOrange : (isCompleted ? Color.green.opacity(0.6) : Color.clear))
                                .frame(width: geometry.size.width * (isCompleted ? 1.0 : progress), height: 4)
                        }
                    }
                    .frame(width: 60, height: 4)

                    Text("\(xpEarned)/\(xpRequired)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isLocked ? .white.opacity(0.3) : .white.opacity(0.5))
                }
            }

            Spacer()

            // Percentage
            Text(isCompleted ? "100%" : "\(Int(progress * 100))%")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isCurrent ? .theme.accentOrange : (isCompleted ? .green.opacity(0.7) : .white.opacity(0.3)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isCurrent ? Color.theme.accentOrange.opacity(0.1) : Color.clear)
    }

    private var statusBackgroundColor: Color {
        if isCurrent {
            return Color.theme.accentOrange.opacity(0.2)
        } else if isCompleted {
            return Color.green.opacity(0.15)
        } else {
            return Color.white.opacity(0.05)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isCurrent {
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.theme.accentOrange)
        } else if isCompleted {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.green.opacity(0.8))
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
    }
}

// MARK: - Level Calculator

struct LevelCalculator {
    /// XP thresholds for each level (cumulative)
    static let levelThresholds: [Int] = {
        var thresholds: [Int] = [0]
        var cumulative = 0
        for level in 1...50 {
            let xpForLevel: Int
            switch level {
            case 1...5:
                xpForLevel = 100 + (level - 1) * 50  // 100, 150, 200, 250, 300
            case 6...15:
                xpForLevel = 400 + (level - 6) * 100  // 400-1300
            case 16...30:
                xpForLevel = 1500 + (level - 16) * 200  // 1500-4300
            case 31...50:
                xpForLevel = 5000 + (level - 31) * 500  // 5000-14500
            default:
                xpForLevel = 15000
            }
            cumulative += xpForLevel
            thresholds.append(cumulative)
        }
        return thresholds
    }()

    static func getLevelInfo(level: Int) -> (xpStart: Int, xpEnd: Int, rank: UserRank) {
        let clampedLevel = max(1, min(level, 50))
        let xpStart = levelThresholds[clampedLevel - 1]
        let xpEnd = levelThresholds[clampedLevel]
        let rank = UserRank.forLevel(clampedLevel)
        return (xpStart, xpEnd, rank)
    }
}

// MARK: - Preview

#Preview {
    LevelProgressView(gamificationService: GamificationService.shared)
}
