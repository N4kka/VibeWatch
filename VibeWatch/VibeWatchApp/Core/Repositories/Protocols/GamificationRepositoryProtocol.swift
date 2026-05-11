import Foundation

struct AwardXPResult {
    let awarded: Bool
    let reason: String?
    let baseXP: Int
    let multiplier: Double
    let streakBonus: Int
    let totalXP: Int
}

protocol GamificationRepositoryProtocol {
    func loadState(userId: String) async -> UserGamificationState?
    func saveState(_ state: UserGamificationState, userId: String) async
    func awardXP(userId: String, action: XPActionType, customXP: Int?, isPro: Bool, source: String?) async throws -> AwardXPResult
}
