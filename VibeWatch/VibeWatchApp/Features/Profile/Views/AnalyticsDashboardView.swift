import SwiftUI
import Charts

/// Main analytics dashboard showing user statistics and insights
struct AnalyticsDashboardView: View {
    @StateObject private var analyticsService = AnalyticsInsightsService.shared
    @StateObject private var authService = AuthService.shared
    @State private var selectedTimeframe: Timeframe = .allTime
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Timeframe Picker
                timeframePicker

                if analyticsService.isLoading {
                    loadingView
                } else if let stats = analyticsService.userStats {
                    // Watch Stats Card
                    WatchStatsCard(stats: stats.watchStats)

                    // Genre Distribution
                    GenreDistributionCard(distribution: stats.genreDistribution)

                    // Watch Streak
                    WatchStreakCard(
                        currentStreak: stats.viewingPatterns.currentStreak,
                        longestStreak: stats.viewingPatterns.longestStreak
                    )

                    // Viewing Heatmap
                    ViewingHeatmapCard(patterns: stats.viewingPatterns)

                    // Top Content
                    TopContentCard(performance: stats.contentPerformance)

                    // Discovery Insights
                    DiscoveryInsightsCard(insights: stats.discoveryInsights)

                    // Milestones
                    if !stats.milestones.isEmpty {
                        MilestonesCard(milestones: stats.milestones)
                    }
                } else if let error = analyticsService.error {
                    errorView(error)
                } else {
                    emptyStateView
                }
            }
            .padding()
        }
        .navigationTitle("Your Stats")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadStats()
        }
        .refreshable {
            await loadStats()
        }
    }

    // MARK: - Subviews

    private var timeframePicker: some View {
        Picker("Timeframe", selection: $selectedTimeframe) {
            Text("All Time").tag(Timeframe.allTime)
            Text("This Year").tag(Timeframe.thisYear)
            Text("This Month").tag(Timeframe.thisMonth)
            Text("Last Month").tag(Timeframe.lastMonth)
            Text("Last Week").tag(Timeframe.lastWeek)
        }
        .pickerStyle(.segmented)
        .onChange(of: selectedTimeframe) { _ in
            Task {
                await loadStats()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Analyzing your watch history...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Error Loading Stats")
                .font(.headline)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Stats Yet")
                .font(.headline)
            Text("Start watching content to see your analytics!")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    // MARK: - Methods

    private func loadStats() async {
        guard let userId = await authService.currentUser?.id else { return }
        await analyticsService.generateUserStatistics(userId: userId, timeframe: selectedTimeframe)
    }
}

// MARK: - Watch Stats Card

struct WatchStatsCard: View {
    let stats: WatchStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "film.fill")
                    .foregroundColor(.accentColor)
                Text("Watch Statistics")
                    .font(.headline)
                Spacer()
            }

            // Grid of stats
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                StatItem(
                    title: "Movies",
                    value: "\(stats.totalMovies)",
                    icon: "film",
                    color: .blue
                )

                StatItem(
                    title: "Episodes",
                    value: "\(stats.totalEpisodes)",
                    icon: "tv",
                    color: .purple
                )

                StatItem(
                    title: "Watch Time",
                    value: "\(stats.totalWatchTimeHours)h",
                    icon: "clock.fill",
                    color: .orange
                )

                StatItem(
                    title: "Completion",
                    value: "\(Int(stats.completionRate * 100))%",
                    icon: "checkmark.circle.fill",
                    color: .green
                )

                StatItem(
                    title: "Avg Session",
                    value: "\(stats.averageSessionMinutes)m",
                    icon: "calendar",
                    color: .indigo
                )

                StatItem(
                    title: "Longest Session",
                    value: "\(stats.longestSessionMinutes)m",
                    icon: "star.fill",
                    color: .yellow
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
}

// MARK: - Genre Distribution Card

struct GenreDistributionCard: View {
    let distribution: GenreStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "theatermasks.fill")
                    .foregroundColor(.accentColor)
                Text("Genre Distribution")
                    .font(.headline)
                Spacer()
            }

            if !distribution.distribution.isEmpty {
                // Pie Chart
                Chart(distribution.distribution.prefix(5)) { genre in
                    SectorMark(
                        angle: .value("Count", genre.count),
                        innerRadius: .ratio(0.5),
                        angularInset: 2
                    )
                    .foregroundStyle(by: .value("Genre", genre.genreName))
                    .cornerRadius(4)
                }
                .frame(height: 250)
                .chartLegend(position: .bottom, spacing: 8)

                // Top Genre Highlight
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top Genre")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(distribution.topGenre.genreName)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("\(distribution.topGenre.count) items (\(Int(distribution.topGenre.percentage * 100))%)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let emerging = distribution.emergingGenre {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Emerging Genre")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                Text(emerging.genreName)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } else {
                Text("No genre data available")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Watch Streak Card

struct WatchStreakCard: View {
    let currentStreak: Int
    let longestStreak: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "flame.fill")
                    .foregroundColor(.orange)
                Text("Watch Streak")
                    .font(.headline)
                Spacer()
            }

            HStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("\(currentStreak)")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.orange)
                    Text("Current Streak")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 60)

                VStack(spacing: 8) {
                    Text("\(longestStreak)")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.yellow)
                    Text("Longest Streak")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            if currentStreak > 0 {
                Text("🔥 Keep watching to maintain your streak!")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Text("Start watching today to begin a new streak!")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Viewing Heatmap Card

struct ViewingHeatmapCard: View {
    let patterns: ViewingPatterns

    private let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.accentColor)
                Text("Viewing Patterns")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Preferred Time: \(patterns.preferredTimeOfDay.rawValue)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Simplified heatmap (showing intensity by day)
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: 4) {
                        Text(dayLabels[day])
                            .font(.caption2)
                            .frame(width: 30, alignment: .leading)
                            .foregroundColor(.secondary)

                        ForEach(0..<24, id: \.self) { hour in
                            Rectangle()
                                .fill(colorForIntensity(patterns.heatmap[day][hour]))
                                .frame(width: 10, height: 20)
                                .cornerRadius(2)
                        }
                    }
                }

                // Hour labels
                HStack(spacing: 4) {
                    Text("")
                        .frame(width: 30)
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text("\(hour)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
    }

    func colorForIntensity(_ minutes: Int) -> Color {
        switch minutes {
        case 0:
            return Color(.systemGray5)
        case 1...30:
            return .blue.opacity(0.3)
        case 31...60:
            return .blue.opacity(0.6)
        case 61...120:
            return .blue.opacity(0.8)
        default:
            return .blue
        }
    }
}

// MARK: - Top Content Card

struct TopContentCard: View {
    let performance: ContentPerformance

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("Top Content")
                    .font(.headline)
                Spacer()
            }

            if !performance.highestRated.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Highest Rated")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    ForEach(performance.highestRated.prefix(3)) { media in
                        HStack {
                            Image(systemName: media.mediaType == .movie ? "film" : "tv")
                                .foregroundColor(.accentColor)
                            Text(media.title.isEmpty ? "Media #\(media.id)" : media.title)
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                }
            }

            if !performance.mostRewatched.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Most Rewatched")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    ForEach(performance.mostRewatched.prefix(3)) { media in
                        HStack {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.orange)
                            Text(media.title.isEmpty ? "Media #\(media.id)" : media.title)
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                }
            }

            if performance.highestRated.isEmpty && performance.mostRewatched.isEmpty {
                Text("No content data available")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Discovery Insights Card

struct DiscoveryInsightsCard: View {
    let insights: DiscoveryInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                Text("Discovery Channels")
                    .font(.headline)
                Spacer()
            }

            if !insights.sourceBreakdown.isEmpty {
                VStack(spacing: 12) {
                    ForEach(Array(insights.sourceBreakdown.sorted(by: { $0.value > $1.value })), id: \.key) { source, count in
                        HStack {
                            Text(source.capitalized)
                                .font(.subheadline)
                            Spacer()
                            Text("\(count)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.accentColor)
                        }

                        // Progress bar
                        GeometryReader { geometry in
                            let total = insights.sourceBreakdown.values.reduce(0, +)
                            let percentage = Double(count) / Double(total)

                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color(.systemGray5))
                                    .frame(height: 6)
                                    .cornerRadius(3)

                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geometry.size.width * percentage, height: 6)
                                    .cornerRadius(3)
                            }
                        }
                        .frame(height: 6)
                    }
                }

                Text("Most successful: \(insights.mostSuccessfulChannel.capitalized)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            } else {
                Text("No discovery data available")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Milestones Card

struct MilestonesCard: View {
    let milestones: [Milestone]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundColor(.yellow)
                Text("Achievements")
                    .font(.headline)
                Spacer()
            }

            ForEach(milestones) { milestone in
                HStack(spacing: 12) {
                    Image(systemName: milestone.icon)
                        .font(.title2)
                        .foregroundColor(.yellow)
                        .frame(width: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(milestone.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(milestone.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding()
                .background(
                    LinearGradient(
                        colors: [Color.yellow.opacity(0.1), Color.orange.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        AnalyticsDashboardView()
    }
}
