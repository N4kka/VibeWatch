import Foundation
import SwiftUI
import Combine
import Supabase

// MARK: - XP Action Types

enum XPActionType: String, CaseIterable {
    case dailyOpen = "daily_open"
    case clipWatched = "clip_watched"
    case clipLiked = "clip_liked"
    case commentPosted = "comment_posted"
    case addedToList = "added_to_list"
    case shareContent = "share_content"
    case streakDay = "streak_day"
    case firstActionOfDay = "first_action_of_day"
    case dailyChallengeCompleted = "daily_challenge_completed"

    var baseXP: Int {
        switch self {
        case .dailyOpen: return 10
        case .clipWatched: return 5
        case .clipLiked: return 2
        case .commentPosted: return 5
        case .addedToList: return 3
        case .shareContent: return 10
        case .streakDay: return 15
        case .firstActionOfDay: return 5
        case .dailyChallengeCompleted: return 0 // Variable based on challenge
        }
    }

    var dailyLimit: Int? {
        switch self {
        case .clipLiked: return 50
        case .commentPosted: return 20
        case .addedToList: return 30
        case .shareContent: return 10
        case .dailyOpen, .streakDay, .firstActionOfDay: return 1
        case .clipWatched, .dailyChallengeCompleted: return nil
        }
    }

    var displayName: String {
        switch self {
        case .dailyOpen: return "Daily Login"
        case .clipWatched: return "Clip Watched"
        case .clipLiked: return "Liked Clip"
        case .commentPosted: return "Comment Posted"
        case .addedToList: return "Added to List"
        case .shareContent: return "Content Shared"
        case .streakDay: return "Streak Day"
        case .firstActionOfDay: return "First Action"
        case .dailyChallengeCompleted: return "Challenge Complete"
        }
    }

    var icon: String {
        switch self {
        case .dailyOpen: return "door.left.hand.open"
        case .clipWatched: return "play.circle.fill"
        case .clipLiked: return "heart.fill"
        case .commentPosted: return "bubble.left.fill"
        case .addedToList: return "plus.circle.fill"
        case .shareContent: return "square.and.arrow.up.fill"
        case .streakDay: return "flame.fill"
        case .firstActionOfDay: return "sunrise.fill"
        case .dailyChallengeCompleted: return "checkmark.seal.fill"
        }
    }

    /// Check if this action contributes to a given daily challenge
    func contributesToChallenge(_ challenge: DailyChallengeType) -> Bool {
        guard let challengeAction = challenge.actionType else { return false }
        return self == challengeAction
    }
}

// MARK: - Level/Rank System

struct UserRank {
    let name: String
    let minLevel: Int
    let maxLevel: Int
    let minXP: Int
    let maxXP: Int
    let color: Color

    static let all: [UserRank] = [
        UserRank(name: "Newcomer", minLevel: 1, maxLevel: 5, minXP: 0, maxXP: 500, color: .gray),
        UserRank(name: "Explorer", minLevel: 6, maxLevel: 10, minXP: 501, maxXP: 2000, color: .green),
        UserRank(name: "Enthusiast", minLevel: 11, maxLevel: 15, minXP: 2001, maxXP: 5000, color: .blue),
        UserRank(name: "Cinephile", minLevel: 16, maxLevel: 20, minXP: 5001, maxXP: 10000, color: .purple),
        UserRank(name: "Movie Buff", minLevel: 21, maxLevel: 25, minXP: 10001, maxXP: 20000, color: .orange),
        UserRank(name: "Film Critic", minLevel: 26, maxLevel: 30, minXP: 20001, maxXP: 40000, color: .red),
        UserRank(name: "Director", minLevel: 31, maxLevel: 40, minXP: 40001, maxXP: 80000, color: .pink),
        UserRank(name: "Legend", minLevel: 41, maxLevel: 50, minXP: 80001, maxXP: Int.max, color: .yellow)
    ]

    static func forLevel(_ level: Int) -> UserRank {
        all.first { level >= $0.minLevel && level <= $0.maxLevel } ?? all[0]
    }

    static func forXP(_ xp: Int) -> UserRank {
        all.last { xp >= $0.minXP } ?? all[0]
    }
}

// MARK: - Badge Definitions

struct BadgeDefinition: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let category: BadgeCategory
    let target: Int
    let color: Color

    enum BadgeCategory: String, CaseIterable {
        case watch = "watch"
        case streak = "streak"
        case social = "social"
        case genre = "genre"

        var displayName: String {
            switch self {
            case .watch: return "Watch"
            case .streak: return "Streak"
            case .social: return "Social"
            case .genre: return "Genre"
            }
        }

        var icon: String {
            switch self {
            case .watch: return "film.fill"
            case .streak: return "flame.fill"
            case .social: return "person.2.fill"
            case .genre: return "theatermasks.fill"
            }
        }
    }

    static let all: [BadgeDefinition] = [
        // Watch badges
        BadgeDefinition(id: "watch_1", name: "First Steps", description: "Watch your first clip", icon: "play.circle", category: .watch, target: 1, color: .blue),
        BadgeDefinition(id: "watch_10", name: "Getting Started", description: "Watch 10 clips", icon: "play.circle.fill", category: .watch, target: 10, color: .blue),
        BadgeDefinition(id: "watch_50", name: "Clip Curious", description: "Watch 50 clips", icon: "film", category: .watch, target: 50, color: .blue),
        BadgeDefinition(id: "watch_100", name: "Binge Watcher", description: "Watch 100 clips", icon: "film.fill", category: .watch, target: 100, color: .purple),
        BadgeDefinition(id: "watch_500", name: "Marathon Runner", description: "Watch 500 clips", icon: "film.stack", category: .watch, target: 500, color: .orange),
        BadgeDefinition(id: "watch_1000", name: "Clip Master", description: "Watch 1000 clips", icon: "film.stack.fill", category: .watch, target: 1000, color: .yellow),

        // Streak badges
        BadgeDefinition(id: "streak_3", name: "Warming Up", description: "3-day streak", icon: "flame", category: .streak, target: 3, color: .orange),
        BadgeDefinition(id: "streak_7", name: "On Fire", description: "7-day streak", icon: "flame.fill", category: .streak, target: 7, color: .orange),
        BadgeDefinition(id: "streak_14", name: "Unstoppable", description: "14-day streak", icon: "bolt.fill", category: .streak, target: 14, color: .red),
        BadgeDefinition(id: "streak_30", name: "Dedicated", description: "30-day streak", icon: "star.fill", category: .streak, target: 30, color: .purple),
        BadgeDefinition(id: "streak_100", name: "Legendary", description: "100-day streak", icon: "crown.fill", category: .streak, target: 100, color: .yellow),

        // Social badges
        BadgeDefinition(id: "like_1", name: "First Like", description: "Like your first clip", icon: "heart", category: .social, target: 1, color: .pink),
        BadgeDefinition(id: "like_50", name: "Supporter", description: "Like 50 clips", icon: "heart.fill", category: .social, target: 50, color: .pink),
        BadgeDefinition(id: "comment_1", name: "First Words", description: "Post your first comment", icon: "bubble.left", category: .social, target: 1, color: .green),
        BadgeDefinition(id: "comment_25", name: "Conversationalist", description: "Post 25 comments", icon: "bubble.left.fill", category: .social, target: 25, color: .green),
        BadgeDefinition(id: "list_5", name: "Curator", description: "Create 5 lists", icon: "list.bullet.rectangle", category: .social, target: 5, color: .indigo),

        // Genre badges
        BadgeDefinition(id: "genre_action", name: "Action Hero", description: "Watch 20 action clips", icon: "bolt.circle.fill", category: .genre, target: 20, color: .red),
        BadgeDefinition(id: "genre_romance", name: "Romantic", description: "Watch 20 romance clips", icon: "heart.circle.fill", category: .genre, target: 20, color: .pink),
        BadgeDefinition(id: "genre_thriller", name: "Thrill Seeker", description: "Watch 20 thriller clips", icon: "exclamationmark.triangle.fill", category: .genre, target: 20, color: .purple),
        BadgeDefinition(id: "genre_comedy", name: "Comedy Fan", description: "Watch 20 comedy clips", icon: "face.smiling.fill", category: .genre, target: 20, color: .yellow),
        BadgeDefinition(id: "genre_scifi", name: "Sci-Fi Voyager", description: "Watch 20 sci-fi clips", icon: "sparkles", category: .genre, target: 20, color: .cyan)
    ]
}

// MARK: - Daily Challenge Definitions

struct DailyChallengeType: Identifiable {
    let id: String
    let description: String
    let target: Int
    let xpReward: Int
    let actionType: XPActionType?
    let icon: String

    static let all: [DailyChallengeType] = [
        DailyChallengeType(id: "watch_3", description: "Watch 3 clips", target: 3, xpReward: 25, actionType: .clipWatched, icon: "play.circle.fill"),
        DailyChallengeType(id: "like_5", description: "Like 5 clips", target: 5, xpReward: 15, actionType: .clipLiked, icon: "heart.fill"),
        DailyChallengeType(id: "list_2", description: "Add 2 items to a list", target: 2, xpReward: 20, actionType: .addedToList, icon: "plus.circle.fill"),
        DailyChallengeType(id: "watch_new_genre", description: "Watch a clip from a new genre", target: 1, xpReward: 30, actionType: nil, icon: "sparkles"),
        DailyChallengeType(id: "complete_5", description: "Complete 5 clips (>70%)", target: 5, xpReward: 40, actionType: .clipWatched, icon: "checkmark.circle.fill")
    ]

    static func random() -> DailyChallengeType {
        all.randomElement() ?? all[0]
    }
}

// MARK: - XP Event for Toast

struct XPEarnedEvent: Identifiable {
    let id = UUID()
    let actionType: XPActionType
    let baseXP: Int
    let proBonus: Int
    let streakBonus: Int
    let totalXP: Int
    let isPro: Bool
    let timestamp: Date

    // Challenge/Badge progress (optional)
    var challengeProgress: ChallengeProgressInfo?

    var displayTitle: String {
        actionType.displayName
    }

    var icon: String {
        actionType.icon
    }
}

// MARK: - Challenge Progress Info (for Toast)

struct ChallengeProgressInfo {
    let title: String
    let icon: String
    let current: Int
    let target: Int
    let isCompleted: Bool

    var progress: Double {
        guard target > 0 else { return 0 }
        return min(1.0, Double(current) / Double(target))
    }

    var progressText: String {
        "\(current)/\(target)"
    }
}

// MARK: - User Gamification State

struct UserGamificationState {
    var totalXP: Int = 0
    var currentLevel: Int = 1
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var lastActivityDate: Date?
    var streakFreezesRemaining: Int = 0

    var rank: UserRank {
        UserRank.forLevel(currentLevel)
    }

    var xpForCurrentLevel: Int {
        levelThreshold(for: currentLevel)
    }

    var xpForNextLevel: Int {
        levelThreshold(for: currentLevel + 1)
    }

    var xpProgressInLevel: Int {
        totalXP - xpForCurrentLevel
    }

    var xpNeededForNextLevel: Int {
        xpForNextLevel - xpForCurrentLevel
    }

    var levelProgress: Double {
        guard xpNeededForNextLevel > 0 else { return 1.0 }
        return Double(xpProgressInLevel) / Double(xpNeededForNextLevel)
    }

    var streakBonusMultiplier: Double {
        switch currentStreak {
        case 0...6: return 1.0
        case 7...13: return 1.1
        case 14...29: return 1.25
        default: return 1.5
        }
    }

    var streakBonusPercentage: Int {
        Int((streakBonusMultiplier - 1.0) * 100)
    }

    private func levelThreshold(for level: Int) -> Int {
        // Exponential growth curve
        switch level {
        case 1: return 0
        case 2...5: return (level - 1) * 100
        case 6...10: return 500 + (level - 5) * 300
        case 11...15: return 2000 + (level - 10) * 600
        case 16...20: return 5000 + (level - 15) * 1000
        case 21...25: return 10000 + (level - 20) * 2000
        case 26...30: return 20000 + (level - 25) * 4000
        case 31...40: return 40000 + (level - 30) * 4000
        default: return 80000 + (level - 40) * 5000
        }
    }

    mutating func calculateLevel() {
        var level = 1
        while levelThreshold(for: level + 1) <= totalXP && level < 50 {
            level += 1
        }
        currentLevel = level
    }
}

// MARK: - Gamification Service

@MainActor
class GamificationService: ObservableObject {
    static let shared = GamificationService()

    // MARK: - Published State

    @Published var userState: UserGamificationState = UserGamificationState()
    @Published var unlockedBadges: [String: Date] = [:]
    @Published var badgeProgress: [String: Int] = [:]
    @Published var currentChallenge: (type: DailyChallengeType, progress: Int, completed: Bool)?
    @Published var recentXPEvent: XPEarnedEvent?
    @Published var recentLevelUp: LevelUpEvent?
    @Published var isLoaded = false

    // MARK: - Dependencies

    private let sqliteService = SQLiteService.shared
    private let localRepository = LocalGamificationRepository.shared
    private let liveRepository = LiveGamificationRepository.shared

    // MARK: - Initialization

    private init() {
        Logger.info("[GamificationService] Initialized")
    }

    // MARK: - Public API

    /// Load user's gamification state from database
    /// Merges local and remote state for cross-device sync
    func loadUserState(userId: String) async {
        Logger.info("[GamificationService] Loading state for user: \(userId)")

        // Load local state first
        let localState = await loadLocalState(userId: userId)
        if let localState {
            userState = localState
        }

        // Fetch remote state; Supabase is authoritative for XP, level, and streak.
        let remoteState = await fetchRemoteState(userId: userId)

        if let remote = remoteState {
            userState = remote
            await localRepository.saveState(remote, userId: userId)
            Logger.info("[GamificationService] Loaded server state - XP: \(userState.totalXP), Level: \(userState.currentLevel)")
        } else if let local = localState {
            userState = local
        } else {
            await initializeUserState(userId: userId)
        }

        // Load and merge badges from remote
        await loadBadges(userId: userId)
        await mergeBadgesFromRemote(userId: userId)

        // Load daily challenge
        await loadOrCreateDailyChallenge(userId: userId)

        isLoaded = true
        Logger.info("[GamificationService] State loaded - Level: \(userState.currentLevel), XP: \(userState.totalXP), Streak: \(userState.currentStreak)")
    }

    /// Explicitly sync gamification state from Supabase
    /// Call this on app launch and foreground resume to ensure cross-device sync
    func syncFromSupabase(userId: String) async {
        Logger.info("[GamificationService] Syncing from Supabase for user: \(userId)")

        guard let remoteState = await fetchRemoteState(userId: userId) else {
            Logger.warning("[GamificationService] No remote state found - using local")
            return
        }

        userState = remoteState
        await localRepository.saveState(remoteState, userId: userId)

        // Merge badges from remote
        await mergeBadgesFromRemote(userId: userId)

        Logger.info("[GamificationService] Synced - XP: \(userState.totalXP), Level: \(userState.currentLevel), Streak: \(userState.currentStreak)")

        // Notify UI to refresh
        objectWillChange.send()
    }

    /// Load state from local SQLite only
    private func loadLocalState(userId: String) async -> UserGamificationState? {
        await localRepository.loadState(userId: userId)
    }

    /// Fetch gamification state from Supabase
    private func fetchRemoteState(userId: String) async -> UserGamificationState? {
        await liveRepository.loadState(userId: userId)
    }

    /// Award XP for an action
    func awardXP(
        userId: String,
        action: XPActionType,
        customXP: Int? = nil,
        isPro: Bool,
        source: String? = nil
    ) async -> XPEarnedEvent? {
        let oldLevel = userState.currentLevel
        let result: AwardXPResult

        do {
            result = try await liveRepository.awardXP(
                userId: userId,
                action: action,
                customXP: customXP,
                isPro: isPro,
                source: source
            )
        } catch {
            Logger.warning("[GamificationService] Remote XP award failed: \(error.localizedDescription)")
            return nil
        }

        guard result.awarded else {
            Logger.debug("[GamificationService] XP not awarded for \(action.rawValue): \(result.reason ?? "unknown")")
            return nil
        }

        if let remoteState = await fetchRemoteState(userId: userId) {
            userState = remoteState
        }

        if userState.currentLevel > oldLevel {
            await onLevelUp(userId: userId, oldLevel: oldLevel, newLevel: userState.currentLevel)
        }

        await updateBadgeProgress(userId: userId, action: action)
        await updateChallengeProgress(userId: userId, action: action)

        // Get challenge progress info for toast (if applicable)
        var challengeProgressInfo: ChallengeProgressInfo?
        if let challenge = currentChallenge, action.contributesToChallenge(challenge.type) {
            challengeProgressInfo = ChallengeProgressInfo(
                title: challenge.type.description,
                icon: challenge.type.icon,
                current: challenge.progress,
                target: challenge.type.target,
                isCompleted: challenge.completed
            )
        }

        // Create event for toast
        var event = XPEarnedEvent(
            actionType: action,
            baseXP: result.baseXP,
            proBonus: isPro ? result.baseXP : 0,
            streakBonus: result.streakBonus,
            totalXP: result.totalXP,
            isPro: isPro,
            timestamp: Date()
        )
        event.challengeProgress = challengeProgressInfo

        recentXPEvent = event

        // Track analytics
        AnalyticsService.shared.logEvent("xp_earned", parameters: [
            "action_type": action.rawValue,
            "base_xp": result.baseXP,
            "multiplier": result.multiplier,
            "streak_bonus": result.streakBonus,
            "total_xp": result.totalXP
        ])

        return event
    }

    /// Record a clip watch (updates streak and awards XP)
    func recordClipWatch(userId: String, clipId: String, completionRate: Double, isPro: Bool) async {
        let today = dateString(for: Date())
        let wasFirstAction = userState.lastActivityDate == nil ||
            dateString(for: userState.lastActivityDate!) != today

        // Award XP if completion > 70%
        if completionRate >= 0.7 {
            _ = await awardXP(userId: userId, action: .clipWatched, isPro: isPro, source: clipId)
        }

        // Award first action of day
        if wasFirstAction {
            _ = await awardXP(userId: userId, action: .firstActionOfDay, isPro: isPro)
            _ = await awardXP(userId: userId, action: .streakDay, isPro: isPro)
            await updateStreakBadges(userId: userId)
        }
    }

    /// Get all badges with progress
    func getAllBadgesWithProgress() -> [(definition: BadgeDefinition, progress: Int, isUnlocked: Bool)] {
        BadgeDefinition.all.map { badge in
            let progress = badgeProgress[badge.id] ?? 0
            let isUnlocked = unlockedBadges[badge.id] != nil
            return (badge, progress, isUnlocked)
        }
    }

    /// Get recently unlocked badge (for celebration)
    func getRecentlyUnlockedBadge() -> BadgeDefinition? {
        guard let recentId = unlockedBadges
            .sorted(by: { $0.value > $1.value })
            .first?.key else { return nil }

        let hourAgo = Date().addingTimeInterval(-3600)
        guard let unlockDate = unlockedBadges[recentId],
              unlockDate > hourAgo else { return nil }

        return BadgeDefinition.all.first { $0.id == recentId }
    }

    // MARK: - Private Methods

    private func initializeUserState(userId: String) async {
        let sql = """
            INSERT OR IGNORE INTO user_gamification (user_id, total_xp, current_level, current_streak, longest_streak, streak_freezes_remaining)
            VALUES (?, 0, 1, 0, 0, 0)
        """
        sqliteService.execute(sql, parameters: [userId])
        Logger.info("[GamificationService] Initialized new user state")
    }

    private func saveUserState(userId: String) async {
        let sql = """
            INSERT OR REPLACE INTO user_gamification
            (user_id, total_xp, current_level, current_streak, longest_streak, last_activity_date, streak_freezes_remaining, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
        """
        sqliteService.execute(sql, parameters: [
            userId,
            userState.totalXP,
            userState.currentLevel,
            userState.currentStreak,
            userState.longestStreak,
            userState.lastActivityDate?.ISO8601Format() ?? NSNull(),
            userState.streakFreezesRemaining
        ])

        // Queue sync to Supabase for cross-device sync
        let syncData: [String: Any] = [
            "user_id": userId,
            "total_xp": userState.totalXP,
            "current_level": userState.currentLevel,
            "current_streak": userState.currentStreak,
            "longest_streak": userState.longestStreak,
            "last_activity_date": userState.lastActivityDate?.ISO8601Format() ?? NSNull(),
            "streak_freezes_remaining": userState.streakFreezesRemaining,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            try await SyncEngine.shared.queueOperation(
                table: "user_gamification",
                operationType: "UPSERT",
                recordId: userId,
                payload: syncData,
                dependsOn: nil
            )
        } catch {
            Logger.error("[Gamification] Failed to queue gamification sync: \(error)")
        }
    }

    private func saveXPTransaction(
        userId: String,
        action: XPActionType,
        baseXP: Int,
        multiplier: Double,
        streakBonus: Double,
        totalXP: Int,
        source: String?
    ) async {
        let transactionId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
            INSERT INTO xp_transactions (id, user_id, action_type, base_xp, multiplier, streak_bonus, total_xp, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        sqliteService.execute(sql, parameters: [
            transactionId,
            userId,
            action.rawValue,
            baseXP,
            multiplier,
            streakBonus,
            totalXP,
            source ?? NSNull(),
            now
        ])

        // Queue sync to Supabase
        let syncData: [String: Any] = [
            "id": transactionId,
            "user_id": userId,
            "action_type": action.rawValue,
            "base_xp": baseXP,
            "multiplier": multiplier,
            "streak_bonus": streakBonus,
            "total_xp": totalXP,
            "source": source ?? NSNull(),
            "created_at": now
        ]

        do {
            try await SyncEngine.shared.queueOperation(
                table: "xp_transactions",
                operationType: "INSERT",
                recordId: transactionId,
                payload: syncData,
                dependsOn: nil
            )
        } catch {
            Logger.error("[Gamification] Failed to queue XP transaction sync: \(error)")
        }
    }

    private func loadBadges(userId: String) async {
        let query = """
            SELECT badge_id, progress, unlocked_at FROM user_badges WHERE user_id = ?
        """
        let rows = (try? await sqliteService.queryRaw(query, parameters: [userId])) ?? []

        for row in rows {
            guard let badgeId = row["badge_id"] as? String else { continue }
            badgeProgress[badgeId] = row["progress"] as? Int ?? 0

            if let unlockedStr = row["unlocked_at"] as? String,
               let date = ISO8601DateFormatter().date(from: unlockedStr) {
                unlockedBadges[badgeId] = date
            }
        }
    }

    /// Fetch and merge badges from Supabase for cross-device sync
    private func mergeBadgesFromRemote(userId: String) async {
        guard let client = SupabaseService.shared.client else {
            return
        }

        do {
            let data = try await client
                .from("user_badges")
                .select()
                .eq("user_id", value: userId)
                .execute()
                .data

            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }

            var hasChanges = false

            for row in rows {
                guard let badgeId = row["badge_id"] as? String else { continue }
                let remoteProgress = row["progress"] as? Int ?? 0
                let localProgress = badgeProgress[badgeId] ?? 0

                // Use max progress (user may have progressed on another device)
                if remoteProgress > localProgress {
                    badgeProgress[badgeId] = remoteProgress
                    hasChanges = true

                    // Check if badge was unlocked remotely
                    if let unlockedStr = row["unlocked_at"] as? String,
                       let remoteUnlockDate = ISO8601DateFormatter().date(from: unlockedStr),
                       unlockedBadges[badgeId] == nil {
                        unlockedBadges[badgeId] = remoteUnlockDate
                    }
                }

                // If local has more progress, we already queued sync in saveBadgeProgress
            }

            if hasChanges {
                // Save merged badges locally
                for (badgeId, progress) in badgeProgress {
                    guard let badge = BadgeDefinition.all.first(where: { $0.id == badgeId }) else { continue }
                    await saveBadgeProgress(userId: userId, badgeId: badgeId, progress: progress, target: badge.target)
                }
                Logger.info("[GamificationService] Merged \(rows.count) badges from remote")
            }
        } catch {
            Logger.warning("[GamificationService] Failed to fetch remote badges: \(error.localizedDescription)")
        }
    }

    private func updateBadgeProgress(userId: String, action: XPActionType) async {
        // Map actions to badges
        let badgesToUpdate: [String]

        switch action {
        case .clipWatched:
            badgesToUpdate = ["watch_1", "watch_10", "watch_50", "watch_100", "watch_500", "watch_1000"]
        case .clipLiked:
            badgesToUpdate = ["like_1", "like_50"]
        case .commentPosted:
            badgesToUpdate = ["comment_1", "comment_25"]
        case .addedToList:
            badgesToUpdate = ["list_5"]
        default:
            return
        }

        for badgeId in badgesToUpdate {
            guard let badge = BadgeDefinition.all.first(where: { $0.id == badgeId }) else { continue }

            let currentProgress = (badgeProgress[badgeId] ?? 0) + 1
            badgeProgress[badgeId] = currentProgress

            // Check if unlocked
            if currentProgress >= badge.target && unlockedBadges[badgeId] == nil {
                unlockedBadges[badgeId] = Date()
                await onBadgeUnlocked(userId: userId, badge: badge)
            }

            // Save progress
            await saveBadgeProgress(userId: userId, badgeId: badgeId, progress: currentProgress, target: badge.target)
        }
    }

    private func updateStreakBadges(userId: String) async {
        let streakBadges = ["streak_3", "streak_7", "streak_14", "streak_30", "streak_100"]

        for badgeId in streakBadges {
            guard let badge = BadgeDefinition.all.first(where: { $0.id == badgeId }) else { continue }

            badgeProgress[badgeId] = userState.currentStreak

            if userState.currentStreak >= badge.target && unlockedBadges[badgeId] == nil {
                unlockedBadges[badgeId] = Date()
                await onBadgeUnlocked(userId: userId, badge: badge)
            }

            await saveBadgeProgress(userId: userId, badgeId: badgeId, progress: userState.currentStreak, target: badge.target)
        }
    }

    private func saveBadgeProgress(userId: String, badgeId: String, progress: Int, target: Int) async {
        let unlocked = unlockedBadges[badgeId]
        let recordId = "\(userId)_\(badgeId)"
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
            INSERT OR REPLACE INTO user_badges (id, user_id, badge_id, progress, target, unlocked_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        sqliteService.execute(sql, parameters: [
            recordId,
            userId,
            badgeId,
            progress,
            target,
            unlocked?.ISO8601Format() ?? NSNull(),
            now
        ])

        // Queue sync to Supabase
        let syncData: [String: Any] = [
            "id": recordId,
            "user_id": userId,
            "badge_id": badgeId,
            "progress": progress,
            "target": target,
            "unlocked_at": unlocked?.ISO8601Format() ?? NSNull(),
            "updated_at": now
        ]

        do {
            try await SyncEngine.shared.queueOperation(
                table: "user_badges",
                operationType: "UPSERT",
                recordId: recordId,
                payload: syncData,
                dependsOn: nil
            )
        } catch {
            Logger.error("[Gamification] Failed to queue badge sync: \(error)")
        }
    }

    private func onBadgeUnlocked(userId: String, badge: BadgeDefinition) async {
        Logger.info("[GamificationService] Badge unlocked: \(badge.name)")

        AnalyticsService.shared.logEvent("badge_unlocked", parameters: [
            "badge_id": badge.id,
            "badge_name": badge.name,
            "category": badge.category.rawValue
        ])
    }

    private func onLevelUp(userId: String, oldLevel: Int, newLevel: Int) async {
        Logger.info("[GamificationService] Level up! \(oldLevel) -> \(newLevel)")

        let newRank = UserRank.forLevel(newLevel)

        // Trigger level up banner
        recentLevelUp = LevelUpEvent(
            oldLevel: oldLevel,
            newLevel: newLevel,
            newRank: newRank,
            timestamp: Date()
        )

        AnalyticsService.shared.logEvent("level_up", parameters: [
            "old_level": oldLevel,
            "new_level": newLevel,
            "rank_name": newRank.name
        ])
    }

    private func loadOrCreateDailyChallenge(userId: String) async {
        let today = dateString(for: Date())

        let query = """
            SELECT * FROM user_daily_challenges WHERE user_id = ? AND challenge_date = ?
        """
        let rows = (try? await sqliteService.queryRaw(query, parameters: [userId, today])) ?? []

        if let row = rows.first {
            let typeId = row["challenge_type"] as? String ?? ""
            let progress = row["progress"] as? Int ?? 0
            let completed = row["completed_at"] != nil

            if let challengeType = DailyChallengeType.all.first(where: { $0.id == typeId }) {
                currentChallenge = (challengeType, progress, completed)
            }
        } else {
            // Create new challenge
            let newChallenge = DailyChallengeType.random()
            currentChallenge = (newChallenge, 0, false)

            let challengeId = UUID().uuidString
            let now = ISO8601DateFormatter().string(from: Date())

            let sql = """
                INSERT INTO user_daily_challenges (id, user_id, challenge_date, challenge_type, challenge_description, target, progress, xp_reward, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
            """
            sqliteService.execute(sql, parameters: [
                challengeId,
                userId,
                today,
                newChallenge.id,
                newChallenge.description,
                newChallenge.target,
                newChallenge.xpReward,
                now
            ])

            // Queue sync to Supabase
            let syncData: [String: Any] = [
                "id": challengeId,
                "user_id": userId,
                "challenge_date": today,
                "challenge_type": newChallenge.id,
                "challenge_description": newChallenge.description,
                "target": newChallenge.target,
                "progress": 0,
                "xp_reward": newChallenge.xpReward,
                "created_at": now
            ]

            do {
                try await SyncEngine.shared.queueOperation(
                    table: "user_daily_challenges",
                    operationType: "INSERT",
                    recordId: challengeId,
                    payload: syncData,
                    dependsOn: nil
                )
            } catch {
                Logger.error("[Gamification] Failed to queue challenge sync: \(error)")
            }
        }
    }

    private func updateChallengeProgress(userId: String, action: XPActionType) async {
        guard var challenge = currentChallenge,
              !challenge.completed,
              challenge.type.actionType == action else { return }

        challenge.progress += 1
        currentChallenge = challenge

        let today = dateString(for: Date())
        let now = ISO8601DateFormatter().string(from: Date())

        if challenge.progress >= challenge.type.target {
            // Complete challenge
            currentChallenge?.completed = true

            let sql = """
                UPDATE user_daily_challenges
                SET progress = ?, completed_at = ?, updated_at = ?
                WHERE user_id = ? AND challenge_date = ?
            """
            sqliteService.execute(sql, parameters: [challenge.progress, now, now, userId, today])

            // Queue sync for challenge completion
            await syncChallengeUpdate(userId: userId, challengeDate: today, progress: challenge.progress, completedAt: now)

            // Award challenge XP
            _ = await awardXP(
                userId: userId,
                action: .dailyChallengeCompleted,
                customXP: challenge.type.xpReward,
                isPro: await ClipQuotaService.shared.checkIsProUser()
            )

            AnalyticsService.shared.logEvent("daily_challenge_completed", parameters: [
                "challenge_type": challenge.type.id,
                "xp_reward": challenge.type.xpReward
            ])
        } else {
            let sql = """
                UPDATE user_daily_challenges
                SET progress = ?, updated_at = ?
                WHERE user_id = ? AND challenge_date = ?
            """
            sqliteService.execute(sql, parameters: [challenge.progress, now, userId, today])

            // Queue sync for progress update
            await syncChallengeUpdate(userId: userId, challengeDate: today, progress: challenge.progress, completedAt: nil)
        }
    }

    /// Queue a sync operation for daily challenge updates
    private func syncChallengeUpdate(userId: String, challengeDate: String, progress: Int, completedAt: String?) async {
        // Get the challenge record ID from the database
        let query = """
            SELECT id, challenge_type, challenge_description, target, xp_reward FROM user_daily_challenges
            WHERE user_id = ? AND challenge_date = ?
        """
        guard let rows = try? await sqliteService.queryRaw(query, parameters: [userId, challengeDate]),
              let row = rows.first,
              let challengeId = row["id"] as? String else {
            return
        }

        let now = ISO8601DateFormatter().string(from: Date())

        var syncData: [String: Any] = [
            "id": challengeId,
            "user_id": userId,
            "challenge_date": challengeDate,
            "challenge_type": row["challenge_type"] as? String ?? "",
            "challenge_description": row["challenge_description"] as? String ?? "",
            "target": row["target"] as? Int ?? 0,
            "progress": progress,
            "xp_reward": row["xp_reward"] as? Int ?? 0,
            "updated_at": now
        ]

        if let completedAt = completedAt {
            syncData["completed_at"] = completedAt
        }

        do {
            try await SyncEngine.shared.queueOperation(
                table: "user_daily_challenges",
                operationType: "UPSERT",
                recordId: challengeId,
                payload: syncData,
                dependsOn: nil
            )
        } catch {
            Logger.error("[Gamification] Failed to queue challenge update sync: \(error)")
        }
    }

    private func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Daily Login Gate

    private func dailyOpenKey(userId: String) -> String {
        "lastDailyOpenAward_\(userId)"
    }

    /// True at most once per local calendar day per user. Used to gate the daily-login
    /// XP award + toast so it only appears once a day, independently of remote state
    /// (which can be unreliable across cold launches / offline).
    func shouldAwardDailyOpen(userId: String) -> Bool {
        let last = UserDefaults.standard.string(forKey: dailyOpenKey(userId: userId))
        return last != dateString(for: Date())
    }

    /// Record that today's daily-login award has been granted, so subsequent launches
    /// today skip it.
    func markDailyOpenAwarded(userId: String) {
        UserDefaults.standard.set(dateString(for: Date()), forKey: dailyOpenKey(userId: userId))
    }
}
