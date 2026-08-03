import SwiftUI

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
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    levelHero
                    streakAndChallenge
                    sectionHeader("gamification.badges.title".localized, trailing: "common.seeAll".localized) {
                        showAllBadges = true
                    }
                    badgesRow
                    sectionHeader("gamification.levels.title".localized, trailing: "common.seeAll".localized) {
                        showLevels = true
                    }
                    levelsTeaser
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color.theme.background.ignoresSafeArea())
            .navigationTitle("gamification.progress.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(Text("common.close".localized))
                }
            }
            .sheet(isPresented: $showAllBadges) {
                NavigationView { BadgeGalleryView(gamificationService: gamificationService) }
            }
            .sheet(isPresented: $showLevels) {
                LevelProgressView(gamificationService: gamificationService)
            }
        }
    }

    // MARK: - Livello

    private var levelHero: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [gamificationService.userState.rank.color,
                                     gamificationService.userState.rank.color.opacity(0.5)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
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
                        .font(.system(size: 12.5, weight: .bold))
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
                            .frame(width: max(0, geo.size.width * gamificationService.userState.levelProgress))
                    }
                }
                .frame(height: 7)

                Text("\(gamificationService.userState.xpProgressInLevel) / \(gamificationService.userState.xpNeededForNextLevel) XP")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Streak + missione del giorno

    private var streakAndChallenge: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.theme.accentOrange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(gamificationService.userState.currentStreak)")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)
                    Text("gamification.dayStreak".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 12)

            challengeCell
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var challengeCell: some View {
        if let challenge = gamificationService.currentChallenge {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(challenge.type.description)
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

    // MARK: - Badge

    private var badgesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(gamificationService.getAllBadgesWithProgress(), id: \.definition.id) { item in
                    ZStack {
                        Circle()
                            .fill(item.isUnlocked ? item.definition.color.opacity(0.2) : Color.white.opacity(0.05))
                            .frame(width: 48, height: 48)
                        Circle()
                            .stroke(
                                item.isUnlocked ? item.definition.color.opacity(0.5) : Color.white.opacity(0.07),
                                lineWidth: 1
                            )
                            .frame(width: 48, height: 48)
                        Image(systemName: item.isUnlocked ? item.definition.icon : "lock")
                            .font(.system(size: 17))
                            .foregroundColor(item.isUnlocked ? item.definition.color : .theme.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Livelli (teaser: la lista completa sta in LevelProgressView)

    private var levelsTeaser: some View {
        Button { showLevels = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.theme.accentOrange.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.theme.accentOrange)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("\("gamification.level".localized) \(gamificationService.userState.currentLevel)")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(.theme.textPrimary)
                        Text(gamificationService.userState.rank.name)
                            .font(.system(size: 11.5))
                            .foregroundColor(.theme.textSecondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule()
                                .fill(Color.theme.accentOrange)
                                .frame(width: max(0, geo.size.width * gamificationService.userState.levelProgress))
                        }
                    }
                    .frame(height: 4)
                    .frame(maxWidth: 130)
                }

                Spacer()

                Text("\(Int(gamificationService.userState.levelProgress * 100))%")
                    .font(.system(size: 12.5, weight: .heavy))
                    .foregroundColor(.theme.accentOrange)
            }
            .padding(14)
            .background(Color.theme.accentOrange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func sectionHeader(_ title: String, trailing: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .kerning(1.2)
                .foregroundColor(Color.white.opacity(0.4))
            Spacer()
            Button(action: action) {
                Text(trailing)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
            }
        }
        .padding(.top, 10)
    }
}
