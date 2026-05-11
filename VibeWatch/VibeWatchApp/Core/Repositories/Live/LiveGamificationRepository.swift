import Foundation

@MainActor
final class LiveGamificationRepository: GamificationRepositoryProtocol {
    static let shared = LiveGamificationRepository(local: .shared)

    private let local: LocalGamificationRepository

    init(local: LocalGamificationRepository) {
        self.local = local
    }

    func loadState(userId: String) async -> UserGamificationState? {
        guard let client = SupabaseService.shared.client else {
            return nil
        }

        do {
            let rows: [RemoteGamificationRow] = try await client
                .from("user_gamification")
                .select()
                .eq("user_id", value: userId)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first else { return nil }
            let state = row.state
            await local.saveState(state, userId: userId)
            return state
        } catch {
            Logger.warning("[GamificationRepository] Remote state fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    func saveState(_ state: UserGamificationState, userId: String) async {
        await local.saveState(state, userId: userId)
    }

    func awardXP(userId: String, action: XPActionType, customXP: Int?, isPro: Bool, source: String?) async throws -> AwardXPResult {
        guard let client = SupabaseService.shared.client else {
            throw SupabaseError.notConfigured
        }

        let params = AwardXPParams(
            p_action_type: action.rawValue,
            p_source: source,
            p_is_pro: isPro,
            p_custom_xp: customXP
        )

        let response: RemoteAwardXPResult = try await client
            .rpc("award_xp", params: params)
            .execute()
            .value

        if response.awarded, let remoteState = await loadState(userId: userId) {
            await local.saveState(remoteState, userId: userId)
        }

        return AwardXPResult(
            awarded: response.awarded,
            reason: response.reason,
            baseXP: response.base_xp ?? customXP ?? action.baseXP,
            multiplier: response.multiplier ?? (isPro ? 2.0 : 1.0),
            streakBonus: response.streak_bonus ?? 0,
            totalXP: response.xp ?? 0
        )
    }
}

private struct AwardXPParams: Encodable {
    let p_action_type: String
    let p_source: String?
    let p_is_pro: Bool
    let p_custom_xp: Int?
}

private struct RemoteAwardXPResult: Decodable {
    let awarded: Bool
    let reason: String?
    let xp: Int?
    let base_xp: Int?
    let multiplier: Double?
    let streak_bonus: Int?
}

private struct RemoteGamificationRow: Decodable {
    let total_xp: Int
    let current_level: Int
    let current_streak: Int
    let longest_streak: Int
    let streak_freezes_remaining: Int
    let last_activity_date: String?

    var state: UserGamificationState {
        var state = UserGamificationState()
        state.totalXP = total_xp
        state.currentLevel = current_level
        state.currentStreak = current_streak
        state.longestStreak = longest_streak
        state.streakFreezesRemaining = streak_freezes_remaining
        if let last_activity_date {
            state.lastActivityDate = LocalGamificationRepository.parseRemoteDate(last_activity_date)
        }
        return state
    }
}
