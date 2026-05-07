import SwiftUI
import Charts

/// Main analytics dashboard showing user statistics and gamification insights
struct AnalyticsDashboardView: View {
    @StateObject private var analyticsService = AnalyticsInsightsService.shared
    @StateObject private var gamificationService = GamificationService.shared
    @StateObject private var authService = AuthService.shared
    @State private var selectedTimeframe: Timeframe = .allTime
    @State private var isRefreshing = false
    @State private var isPro = false
    @State private var showLevelProgress = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - Gamification Section

                // Level Hero Card (Tappable)
                levelHeroCard
                    .onTapGesture {
                        showLevelProgress = true
                    }

                // Combined Streak & Daily Challenge Card
                streakAndChallengeCard

                // Badges Preview (Horizontal Scroll)
                badgesPreviewSection

                // MARK: - Watch Statistics Section

                statsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color.theme.background.ignoresSafeArea())
        .navigationTitle("Your Stats")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showLevelProgress) {
            LevelProgressView(gamificationService: gamificationService)
        }
        .levelUpBanner(gamificationService: gamificationService)
        .task {
            await loadData()
        }
        .refreshable {
            await loadData()
        }
    }

    // MARK: - Level Hero Card (Simplified & Tappable)

    private var levelHeroCard: some View {
        HStack(spacing: 16) {
            // Rank Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [gamificationService.userState.rank.color, gamificationService.userState.rank.color.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)

                Text("\(gamificationService.userState.currentLevel)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }

            // Level Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Level \(gamificationService.userState.currentLevel)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text(gamificationService.userState.rank.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(gamificationService.userState.rank.color)
                }

                // XP Progress (compact)
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 8)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: [.theme.accentOrange, .orange],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * gamificationService.userState.levelProgress, height: 8)
                        }
                    }
                    .frame(height: 8)

                    Text("\(gamificationService.userState.xpProgressInLevel)/\(gamificationService.userState.xpNeededForNextLevel)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 70, alignment: .trailing)
                }
            }

            Spacer()

            // Pro Badge & Chevron
            HStack(spacing: 8) {
                if isPro {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text("x2")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.theme.accentOrange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.theme.accentOrange.opacity(0.2)))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(gamificationService.userState.rank.color.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Combined Streak & Challenge Card

    private var streakAndChallengeCard: some View {
        HStack(spacing: 0) {
            // Streak Section
            HStack(spacing: 12) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(gamificationService.userState.currentStreak)")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Text("Day Streak")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }

                if gamificationService.userState.streakBonusPercentage > 0 {
                    Text("+\(gamificationService.userState.streakBonusPercentage)%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 12)

            // Daily Challenge Section
            if let challenge = gamificationService.currentChallenge {
                HStack(spacing: 12) {
                    Image(systemName: challenge.type.icon)
                        .font(.system(size: 24))
                        .foregroundColor(challenge.completed ? .green : .theme.accentOrange)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(challenge.completed ? "Done!" : "\(challenge.progress)/\(challenge.type.target)")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(challenge.completed ? .green : .white)

                            Text("+\(challenge.type.xpReward)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.theme.accentOrange)
                        }

                        // Mini progress bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 4)

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(challenge.completed ? Color.green : Color.theme.accentOrange)
                                    .frame(width: geometry.size.width * min(1.0, Double(challenge.progress) / Double(challenge.type.target)), height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
            } else {
                VStack {
                    Text("No Challenge")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: - Badges Preview Section

    private var badgesPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Badges")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                NavigationLink(destination: BadgeGalleryView(gamificationService: gamificationService)) {
                    HStack(spacing: 4) {
                        Text("See all")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.theme.accentOrange)
                }
            }

            // Horizontal scroll of badges
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    let badges = gamificationService.getAllBadgesWithProgress()
                    let sortedBadges = badges.sorted { $0.isUnlocked && !$1.isUnlocked }

                    ForEach(sortedBadges.prefix(10), id: \.definition.id) { item in
                        badgeIcon(item)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func badgeIcon(_ item: (definition: BadgeDefinition, progress: Int, isUnlocked: Bool)) -> some View {
        ZStack {
            Circle()
                .fill(item.isUnlocked ? item.definition.color.opacity(0.2) : Color.white.opacity(0.05))
                .frame(width: 48, height: 48)

            Image(systemName: item.definition.icon)
                .font(.system(size: 20))
                .foregroundColor(item.isUnlocked ? item.definition.color : .white.opacity(0.2))

            if !item.isUnlocked {
                Circle()
                    .fill(Color.black.opacity(0.3))
                    .frame(width: 48, height: 48)

                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with timeframe picker
            HStack {
                Text("Your Activity")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                Menu {
                    ForEach([Timeframe.allTime, .thisYear, .thisMonth, .lastWeek], id: \.self) { timeframe in
                        Button {
                            selectedTimeframe = timeframe
                            Task { await loadStats() }
                        } label: {
                            HStack {
                                Text(timeframe.displayName)
                                if selectedTimeframe == timeframe {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedTimeframe.displayName)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.theme.accentOrange)
                }
            }

            // Stats Content
            if analyticsService.isLoading {
                loadingView
            } else if let stats = analyticsService.userStats {
                statsGrid(stats: stats.watchStats)

                GenreDistributionCard(distribution: stats.genreDistribution)

                if let mood = stats.moodAnalysis {
                    MoodAnalysisCard(moodAnalysis: mood)
                }

                ViewingHeatmapCard(patterns: stats.viewingPatterns)

                TopContentCard(performance: stats.contentPerformance)

                DiscoveryInsightsCard(insights: stats.discoveryInsights)
            } else if let error = analyticsService.error {
                errorView(error)
            } else {
                emptyStateView
            }
        }
    }

    private func statsGrid(stats: WatchStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatItem(title: "Movies", value: "\(stats.totalMovies)", icon: "film", color: .blue)
            StatItem(title: "Episodes", value: "\(stats.totalEpisodes)", icon: "tv", color: .purple)
            StatItem(title: "Watch Time", value: "\(stats.totalWatchTimeHours)h", icon: "clock.fill", color: .orange)
            StatItem(title: "Completion", value: "\(Int(stats.completionRate * 100))%", icon: "checkmark.circle.fill", color: .green)
        }
    }

    // MARK: - Loading/Error/Empty Views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.theme.accentOrange)
            Text("Loading stats...")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("Error Loading Stats")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text(error)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.3))
            Text("No Stats Yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text("Start watching to see your analytics!")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    // MARK: - Data Loading

    private func loadData() async {
        guard let userId = await authService.currentUser?.id else { return }

        isPro = await ClipQuotaService.shared.checkIsProUser()

        async let gamificationLoad: () = gamificationService.loadUserState(userId: userId)
        async let statsLoad: () = loadStats()

        _ = await (gamificationLoad, statsLoad)
    }

    private func loadStats() async {
        guard let userId = await authService.currentUser?.id else { return }
        await analyticsService.generateUserStatistics(userId: userId, timeframe: selectedTimeframe)
    }
}

// MARK: - Timeframe Extension

extension Timeframe {
    var displayName: String {
        switch self {
        case .allTime: return "All Time"
        case .thisYear: return "This Year"
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .lastWeek: return "This Week"
        }
    }
}

// MARK: - Stat Item

struct StatItem: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Genre Distribution Card

struct GenreDistributionCard: View {
    let distribution: GenreStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "theatermasks.fill")
                    .foregroundColor(.purple)
                Text("Genre Distribution")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }

            if !distribution.distribution.isEmpty {
                Chart(distribution.distribution.prefix(5)) { genre in
                    SectorMark(
                        angle: .value("Count", genre.count),
                        innerRadius: .ratio(0.5),
                        angularInset: 2
                    )
                    .foregroundStyle(by: .value("Genre", genre.genreName))
                    .cornerRadius(4)
                }
                .frame(height: 180)
                .chartLegend(position: .bottom, spacing: 8)
            } else {
                Text("No genre data available")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Viewing Heatmap Card

struct ViewingHeatmapCard: View {
    let patterns: ViewingPatterns
    private let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.blue)
                Text("Viewing Patterns")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()

                Text(patterns.preferredTimeOfDay.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.theme.accentOrange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.theme.accentOrange.opacity(0.2)))
            }

            VStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: 2) {
                        Text(dayLabels[day])
                            .font(.system(size: 9))
                            .frame(width: 14, alignment: .leading)
                            .foregroundColor(.white.opacity(0.4))

                        ForEach(0..<24, id: \.self) { hour in
                            Rectangle()
                                .fill(colorForIntensity(patterns.heatmap[day][hour]))
                                .frame(height: 12)
                                .cornerRadius(2)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }

    func colorForIntensity(_ minutes: Int) -> Color {
        switch minutes {
        case 0: return Color.white.opacity(0.05)
        case 1...30: return Color.blue.opacity(0.3)
        case 31...60: return Color.blue.opacity(0.5)
        case 61...120: return Color.blue.opacity(0.7)
        default: return Color.blue
        }
    }
}

// MARK: - Top Content Card

struct TopContentCard: View {
    let performance: ContentPerformance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("Top Content")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }

            if !performance.mostRewatched.isEmpty {
                ForEach(performance.mostRewatched.prefix(3)) { media in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text(media.title.isEmpty ? "Media #\(media.id)" : media.title)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            } else {
                Text("No content data available")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Discovery Insights Card

struct DiscoveryInsightsCard: View {
    let insights: DiscoveryInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.cyan)
                Text("Discovery Channels")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }

            if !insights.sourceBreakdown.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(insights.sourceBreakdown.sorted(by: { $0.value > $1.value })), id: \.key) { source, count in
                        HStack {
                            Text(source.capitalized)
                                .font(.system(size: 13))
                                .foregroundColor(.white)

                            GeometryReader { geometry in
                                let total = insights.sourceBreakdown.values.reduce(0, +)
                                let percentage = Double(count) / Double(max(total, 1))

                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.1))
                                        .frame(height: 4)

                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.theme.accentOrange)
                                        .frame(width: geometry.size.width * percentage, height: 4)
                                }
                            }
                            .frame(height: 4)

                            Text("\(count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.theme.accentOrange)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            } else {
                Text("No discovery data available")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Mood Analysis Card

struct MoodAnalysisCard: View {
    let moodAnalysis: MoodAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "theatermasks")
                    .foregroundColor(.pink)
                Text("Mood Profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }

            if moodAnalysis.moodDistribution.isEmpty {
                Text("Not enough data yet — keep watching to see your mood profile.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    ForEach(
                        Array(moodAnalysis.moodDistribution.sorted(by: { $0.value > $1.value })),
                        id: \.key
                    ) { mood, count in
                        HStack {
                            Text(mood)
                                .font(.system(size: 13))
                                .foregroundColor(.white)

                            GeometryReader { geometry in
                                let total = moodAnalysis.moodDistribution.values.reduce(0, +)
                                let percentage = Double(count) / Double(max(total, 1))

                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.1))
                                        .frame(height: 4)

                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.pink)
                                        .frame(width: geometry.size.width * percentage, height: 4)
                                }
                            }
                            .frame(height: 4)

                            Text("\(count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.pink)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        AnalyticsDashboardView()
    }
}
