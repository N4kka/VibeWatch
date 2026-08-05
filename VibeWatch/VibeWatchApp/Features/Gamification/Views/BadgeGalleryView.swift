import SwiftUI

/// Full badge gallery showing all badges with progress
struct BadgeGalleryView: View {
    @ObservedObject var gamificationService: GamificationService
    @State private var selectedCategory: BadgeDefinition.BadgeCategory?
    @State private var selectedBadge: BadgeDefinition?

    private var categories: [BadgeDefinition.BadgeCategory] {
        BadgeDefinition.BadgeCategory.allCases
    }

    private var filteredBadges: [(definition: BadgeDefinition, progress: Int, isUnlocked: Bool)] {
        let all = gamificationService.getAllBadgesWithProgress()
        if let category = selectedCategory {
            return all.filter { $0.definition.category == category }
        }
        return all
    }

    private var unlockedCount: Int {
        gamificationService.getAllBadgesWithProgress().filter { $0.isUnlocked }.count
    }

    private var totalCount: Int {
        BadgeDefinition.all.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header Stats
                headerStats

                // Category Filter
                categoryFilter

                // Badge Grid
                badgeGrid
            }
            .padding()
        }
        .background(Color.theme.background.ignoresSafeArea())
        .navigationTitle("gamification.badges.title".localized)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $selectedBadge) { badge in
            BadgeDetailSheet(
                badge: badge,
                progress: gamificationService.badgeProgress[badge.id] ?? 0,
                isUnlocked: gamificationService.unlockedBadges[badge.id] != nil,
                unlockedAt: gamificationService.unlockedBadges[badge.id]
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header Stats

    private var headerStats: some View {
        VStack(spacing: 16) {
            // Progress Ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 12)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: Double(unlockedCount) / Double(totalCount))
                    .stroke(
                        LinearGradient(
                            colors: [.theme.accentOrange, .yellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text("\(unlockedCount)")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text(String(format: "gamification.badges.ofTotal".localized, totalCount))
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            Text("gamification.badges.collected".localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.vertical, 20)
    }

    // MARK: - Category Filter

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // All button
                CategoryButton(
                    title: "All",
                    icon: "square.grid.2x2.fill",
                    isSelected: selectedCategory == nil,
                    color: .theme.accentOrange
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedCategory = nil
                    }
                }

                ForEach(categories, id: \.self) { category in
                    CategoryButton(
                        title: category.displayName,
                        icon: category.icon,
                        isSelected: selectedCategory == category,
                        color: colorForCategory(category)
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedCategory = category
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Badge Grid

    private var badgeGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16)
        ], spacing: 16) {
            ForEach(filteredBadges, id: \.definition.id) { item in
                BadgeCell(
                    badge: item.definition,
                    progress: item.progress,
                    isUnlocked: item.isUnlocked
                )
                .onTapGesture {
                    selectedBadge = item.definition
                }
            }
        }
    }

    private func colorForCategory(_ category: BadgeDefinition.BadgeCategory) -> Color {
        switch category {
        case .watch: return .blue
        case .streak: return .orange
        case .social: return .pink
        case .genre: return .purple
        }
    }
}

// MARK: - Category Button

struct CategoryButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(isSelected ? color : Color.white.opacity(0.1))
            )
        }
    }
}

// MARK: - Badge Cell

struct BadgeCell: View {
    let badge: BadgeDefinition
    let progress: Int
    let isUnlocked: Bool

    private var progressRatio: Double {
        min(1.0, Double(progress) / Double(badge.target))
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background circle
                Circle()
                    .fill(isUnlocked ? badge.color.opacity(0.2) : Color.white.opacity(0.05))
                    .frame(width: 70, height: 70)

                // Progress ring (if not unlocked)
                if !isUnlocked {
                    Circle()
                        .trim(from: 0, to: progressRatio)
                        .stroke(badge.color.opacity(0.5), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 70, height: 70)
                        .rotationEffect(.degrees(-90))
                }

                // Icon
                Image(systemName: badge.icon)
                    .font(.system(size: 28))
                    .foregroundColor(isUnlocked ? badge.color : .white.opacity(0.3))

                // Lock overlay if not unlocked
                if !isUnlocked {
                    Circle()
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 70, height: 70)

                    Image(systemName: "lock.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                        .offset(x: 22, y: 22)
                }
            }

            Text(badge.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isUnlocked ? .white : .white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if !isUnlocked {
                Text("\(progress)/\(badge.target)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isUnlocked ? badge.color.opacity(0.3) : Color.white.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

// MARK: - Badge Detail Sheet

struct BadgeDetailSheet: View {
    let badge: BadgeDefinition
    let progress: Int
    let isUnlocked: Bool
    let unlockedAt: Date?

    @Environment(\.dismiss) private var dismiss

    private var progressRatio: Double {
        min(1.0, Double(progress) / Double(badge.target))
    }

    var body: some View {
        VStack(spacing: 24) {
            // Badge Icon Large
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [badge.color.opacity(0.3), badge.color.opacity(0.1)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 140, height: 140)

                if !isUnlocked {
                    Circle()
                        .trim(from: 0, to: progressRatio)
                        .stroke(badge.color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 140, height: 140)
                        .rotationEffect(.degrees(-90))
                }

                Image(systemName: badge.icon)
                    .font(.system(size: 56))
                    .foregroundColor(isUnlocked ? badge.color : badge.color.opacity(0.4))
            }
            .overlay(
                Group {
                    if isUnlocked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.green)
                            .background(Circle().fill(Color.theme.background).padding(-4))
                            .offset(x: 50, y: 50)
                    }
                }
            )

            // Badge Info
            VStack(spacing: 8) {
                Text(badge.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text(badge.description)
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    Image(systemName: badge.category.icon)
                        .font(.system(size: 14))
                    Text(badge.category.displayName)
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(badge.color)
                .padding(.top, 4)
            }

            // Progress or Unlock Date
            if isUnlocked {
                if let date = unlockedAt {
                    VStack(spacing: 4) {
                        Text("gamification.badges.unlocked".localized)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                        Text(date, style: .date)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.green)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.green.opacity(0.1))
                    )
                }
            } else {
                VStack(spacing: 8) {
                    Text("common.progress".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))

                    HStack(spacing: 4) {
                        Text("\(progress)")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                        Text("/ \(badge.target)")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 12)

                            RoundedRectangle(cornerRadius: 6)
                                .fill(badge.color)
                                .frame(width: geometry.size.width * progressRatio, height: 12)
                        }
                    }
                    .frame(height: 12)
                    .padding(.horizontal, 40)

                    Text("\(Int(progressRatio * 100))% complete")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Spacer()
        }
        .padding(.top, 32)
        .padding(.horizontal, 24)
        .background(Color.theme.background.ignoresSafeArea())
    }
}

// MARK: - Identifiable Conformance

extension BadgeDefinition: Hashable {
    static func == (lhs: BadgeDefinition, rhs: BadgeDefinition) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        BadgeGalleryView(gamificationService: GamificationService.shared)
    }
}
