import Foundation
import Combine

/// Protocol defining the gamification service interface.
/// Enables testability through dependency injection and mocking.
@MainActor
protocol GamificationServiceProtocol: AnyObject, ObservableObject {
    // MARK: - Published Properties

    var userState: UserGamificationState { get }
    var unlockedBadges: [String: Date] { get }
    var badgeProgress: [String: Int] { get }
    var currentChallenge: (type: DailyChallengeType, progress: Int, completed: Bool)? { get }
    var recentXPEvent: XPEarnedEvent? { get set }
    var recentLevelUp: LevelUpEvent? { get set }
    var isLoaded: Bool { get }

    // MARK: - State Management

    func loadUserState(userId: String) async
    func syncFromSupabase(userId: String) async

    // MARK: - XP & Rewards

    func awardXP(
        userId: String,
        action: XPActionType,
        customXP: Int?,
        isPro: Bool,
        source: String?
    ) async

    // MARK: - Activity Tracking

    func recordClipWatch(userId: String, clipId: String, completionRate: Double, isPro: Bool) async

    // MARK: - Badge Information

    func getAllBadgesWithProgress() -> [(definition: BadgeDefinition, progress: Int, isUnlocked: Bool)]
    func getRecentlyUnlockedBadge() -> BadgeDefinition?
}
