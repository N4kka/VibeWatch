import SwiftUI

enum GamificationProgressPresentation {
    static func previewLevels(currentLevel: Int) -> [Int] {
        let currentLevel = min(max(currentLevel, 1), 50)
        let nextRankLevel = UserRank.all.first { $0.minLevel > currentLevel }?.minLevel
        let candidates = [currentLevel, currentLevel + 1, currentLevel + 2, nextRankLevel]
            .compactMap { $0 }
            .filter { $0 <= 50 }

        return candidates.reduce(into: []) { levels, level in
            if !levels.contains(level) {
                levels.append(level)
            }
        }
    }
}

/// Redesign 2.0 — "I tuoi progressi": la casa unica della gamification.
///
/// Prima livello, streak, missione, badge e livelli vivevano sparsi (badge flottante, dashboard
/// analytics, galleria). Questa schermata li compone nell'ordine del prototipo: livello in
/// testa, streak+missione, badge, livelli. Non calcola niente: legge `GamificationService`,
/// che è già la fonte unica dello stato XP.
struct GamificationProgressView: View {
    @ObservedObject var gamificationService: GamificationService
    @Environment(\.dismiss) private var dismiss

    @State private var showAllBadges = false
    @State private var showLevels = false

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Text("gamification.progress.title".localized)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)

                    Spacer()

                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(Text("common.close".localized))
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 16)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        levelHero

                        Spacer().frame(height: 12)
                        streakAndChallenge

                        sectionHeader("gamification.missionsToday".localized)
                            .padding(.top, 22)
                            .padding(.bottom, 10)
                        dailyMissionsCard

                        sectionHeader(
                            "gamification.badges.title".localized,
                            trailing: "common.seeAll".localized
                        ) {
                            showAllBadges = true
                        }
                        .padding(.top, 22)
                        .padding(.bottom, 10)
                        badgesRow

                        sectionHeader("gamification.levels.title".localized)
                            .padding(.top, 22)
                            .padding(.bottom, 10)
                        levelsCard
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAllBadges) {
            NavigationView { BadgeGalleryView(gamificationService: gamificationService) }
        }
        .sheet(isPresented: $showLevels) {
            LevelProgressView(gamificationService: gamificationService)
        }
    }

    // MARK: - Livello

    private var levelHero: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(hex: "373941"))
                    .frame(width: 56, height: 56)

                Text("\(gamificationService.userState.currentLevel)")
                    .font(.system(size: 23, weight: .heavy))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("\("gamification.level".localized) \(gamificationService.userState.currentLevel)")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)

                    Text(gamificationService.userState.rank.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.theme.textSecondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.theme.accentOrange, Color(hex: "ffa057")],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(
                                width: geo.size.width
                                    * min(max(gamificationService.userState.levelProgress, 0), 1)
                            )
                    }
                }
                .frame(height: 7)

                HStack(alignment: .firstTextBaseline) {
                    Text("\(gamificationService.userState.xpProgressInLevel) / \(gamificationService.userState.xpNeededForNextLevel) XP")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)

                    Spacer(minLength: 8)

                    Text(
                        String(
                            format: "gamification.xpToNext".localized,
                            max(
                                0,
                                gamificationService.userState.xpNeededForNextLevel
                                    - gamificationService.userState.xpProgressInLevel
                            )
                        )
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.theme.cardBackground.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Streak + missione del giorno

    private var streakAndChallenge: some View {
        HStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 19))
                    .foregroundColor(.theme.accentOrange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(gamificationService.userState.currentStreak)")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)

                    Text("gamification.dayStreak".localized)
                        .font(.system(size: 11.5))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            .frame(width: 132, alignment: .leading)
            .padding(.leading, 14)
            .padding(.vertical, 16)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 12)

            challengeCell
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(Color.theme.cardBackground.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var challengeCell: some View {
        if let challenge = gamificationService.currentChallenge {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localizedChallengeTitle(challenge.type))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)

                    Text("+\(challenge.type.xpReward) XP")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.theme.accentOrange)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(challenge.completed ? Color.green : Color.theme.accentOrange)
                            .frame(width: geo.size.width * min(1, Double(challenge.progress) / Double(challenge.type.target)))
                    }
                }
                .frame(height: 5)

                Text("\(min(challenge.progress, challenge.type.target))/\(challenge.type.target)")
                    .font(.system(size: 10.5))
                    .foregroundColor(.theme.textSecondary)
            }
        } else {
            // Nessuna missione oggi: si dice, non si finge una missione vuota.
            Text("gamification.challenge.none".localized)
                .font(.system(size: 12))
                .foregroundColor(.theme.textSecondary)
        }
    }

    // MARK: - Missioni di oggi

    private var dailyMissionsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(dailyMissions.enumerated()), id: \.element.id) { index, mission in
                dailyMissionRow(mission)

                if index < dailyMissions.count - 1 {
                    Rectangle()
                        .fill(Color.theme.separator)
                        .frame(height: 1)
                }
            }
        }
        .background(Color.theme.cardBackground.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var dailyMissions: [DailyMissionPresentation] {
        var missions = [
            DailyMissionPresentation(
                id: "open-app",
                title: "gamification.mission.openApp".localized,
                reward: XPActionType.dailyOpen.baseXP,
                isCompleted: true
            ),
            DailyMissionPresentation(
                id: "keep-streak",
                title: "gamification.mission.keepStreak".localized,
                reward: XPActionType.streakDay.baseXP,
                isCompleted: gamificationService.userState.currentStreak > 0
            )
        ]

        if let challenge = gamificationService.currentChallenge {
            missions.append(
                DailyMissionPresentation(
                    id: challenge.type.id,
                    title: localizedChallengeTitle(challenge.type),
                    reward: challenge.type.xpReward,
                    isCompleted: challenge.completed
                )
            )
        } else {
            missions.append(
                DailyMissionPresentation(
                    id: "no-challenge",
                    title: "gamification.challenge.none".localized,
                    reward: nil,
                    isCompleted: false
                )
            )
        }

        return missions
    }

    private func dailyMissionRow(_ mission: DailyMissionPresentation) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        mission.isCompleted
                            ? Color.green.opacity(0.22)
                            : Color.white.opacity(0.07)
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(
                        mission.isCompleted
                            ? Color.green
                            : Color.theme.textSecondary.opacity(0.45)
                    )
            }

            Text(mission.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(
                    mission.isCompleted
                        ? Color.theme.textSecondary.opacity(0.78)
                        : Color.theme.textPrimary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 8)

            if let reward = mission.reward {
                Text("+\(reward) XP")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.theme.accentOrange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.theme.accentOrange.opacity(0.16))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
    }

    // MARK: - Badge

    private var badgesRow: some View {
        GeometryReader { geometry in
            let badgeSize = min(48, max(40, (geometry.size.width - 50) / 6))

            HStack(spacing: 10) {
                ForEach(Array(visibleBadges), id: \.definition.id) { item in
                    ZStack {
                        Circle()
                            .fill(
                                item.isUnlocked
                                    ? item.definition.color.opacity(0.2)
                                    : Color.theme.cardBackground.opacity(0.82)
                            )

                        Circle()
                            .stroke(
                                item.isUnlocked
                                    ? item.definition.color.opacity(0.72)
                                    : Color.white.opacity(0.09),
                                lineWidth: 1
                            )

                        Image(systemName: item.isUnlocked ? item.definition.icon : "lock")
                            .font(.system(size: badgeSize / 3, weight: .medium))
                            .foregroundColor(
                            item.isUnlocked
                                ? item.definition.color
                                : Color.theme.textSecondary.opacity(0.62)
                            )
                    }
                    .frame(width: badgeSize, height: badgeSize)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 48)
    }

    private var visibleBadges: ArraySlice<(definition: BadgeDefinition, progress: Int, isUnlocked: Bool)> {
        gamificationService
            .getAllBadgesWithProgress()
            .sorted { first, second in
                if first.isUnlocked != second.isUnlocked {
                    return first.isUnlocked && !second.isUnlocked
                }
                return first.definition.id < second.definition.id
            }
            .prefix(6)
    }

    // MARK: - Livelli

    private var levelsCard: some View {
        Button { showLevels = true } label: {
            VStack(spacing: 0) {
                let levels = GamificationProgressPresentation.previewLevels(
                    currentLevel: gamificationService.userState.currentLevel
                )

                ForEach(Array(levels.enumerated()), id: \.element) { index, level in
                    compactLevelRow(level)

                    if index < levels.count - 1 {
                        Rectangle()
                            .fill(Color.theme.separator)
                            .frame(height: 1)
                    }
                }
            }
            .background(Color.theme.cardBackground.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func compactLevelRow(_ level: Int) -> some View {
        let isCurrent = level == gamificationService.userState.currentLevel
        let levelInfo = LevelCalculator.getLevelInfo(level: level)
        let progress = isCurrent
            ? min(max(gamificationService.userState.levelProgress, 0), 1)
            : 0

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        isCurrent
                            ? Color.theme.accentOrange.opacity(0.18)
                            : Color.white.opacity(0.06)
                    )
                    .frame(width: 30, height: 30)

                Image(systemName: isCurrent ? "arrow.right" : "lock")
                    .font(.system(size: isCurrent ? 12 : 10, weight: .bold))
                    .foregroundColor(
                        isCurrent
                            ? Color.theme.accentOrange
                            : Color.theme.textSecondary.opacity(0.55)
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("\("gamification.level".localized) \(level)")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(
                            isCurrent
                                ? Color.theme.textPrimary
                                : Color.theme.textSecondary.opacity(0.72)
                        )

                    Text(levelInfo.rank.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.theme.textSecondary.opacity(isCurrent ? 0.82 : 0.58))
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(Color.theme.accentOrange)
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(width: 130, height: 4)
            }

            Spacer()

            Text("\(Int(progress * 100))%")
                .font(.system(size: 14, weight: .heavy))
                .foregroundColor(
                    isCurrent
                        ? Color.theme.accentOrange
                        : Color.theme.textSecondary.opacity(0.5)
                )
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 55)
        .background(isCurrent ? Color.theme.accentOrange.opacity(0.1) : Color.clear)
    }

    private func localizedChallengeTitle(_ challenge: DailyChallengeType) -> String {
        let key = "gamification.challenge.\(challenge.id)"
        let localizedTitle = key.localized
        return localizedTitle == key ? challenge.description : localizedTitle
    }

    private func sectionHeader(
        _ title: String,
        trailing: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .kerning(1.2)
                .foregroundColor(Color.white.opacity(0.4))

            Spacer()

            if let trailing, let action {
                Button(action: action) {
                    Text(trailing)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.theme.accentOrange)
                }
            } else if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
            }
        }
    }
}

private struct DailyMissionPresentation: Identifiable {
    let id: String
    let title: String
    let reward: Int?
    let isCompleted: Bool
}
