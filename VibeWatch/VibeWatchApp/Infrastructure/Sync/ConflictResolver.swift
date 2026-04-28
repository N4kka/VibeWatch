import Foundation

// MARK: - ConflictResolverProtocol

/// Protocol defining the conflict resolution interface for testability.
/// Enables dependency injection and mocking in tests.
public protocol ConflictResolverProtocol: AnyObject, Sendable {
    /// Resolves a conflict between local and remote records.
    ///
    /// - Parameters:
    ///   - table: The database table name
    ///   - local: The local record as a dictionary
    ///   - remote: The remote record as a dictionary
    /// - Returns: The resolved record to use
    func resolve(
        table: String,
        local: [String: Any],
        remote: [String: Any]
    ) -> ResolvedRecord
}

// MARK: - ResolvedRecord

/// Result of conflict resolution containing the merged record and metadata.
public struct ResolvedRecord {
    /// The resolved/merged record data
    public let record: [String: Any]

    /// The strategy that was used to resolve the conflict
    public let strategyUsed: ConflictStrategy

    /// Whether the local record was modified (vs. just taking remote as-is)
    public let wasModified: Bool

    /// Source of the winning value (for logging/debugging)
    public let source: RecordSource

    public enum RecordSource: String {
        case local
        case remote
        case merged
    }

    public init(
        record: [String: Any],
        strategyUsed: ConflictStrategy,
        wasModified: Bool,
        source: RecordSource
    ) {
        self.record = record
        self.strategyUsed = strategyUsed
        self.wasModified = wasModified
        self.source = source
    }
}

// MARK: - ConflictResolver

/// Implements unified conflict resolution for the SyncEngine.
///
/// Supports multiple strategies based on table type:
/// - `.union`: Merge items from both sources (lists, badges)
/// - `.maxWins`: Take maximum values (gamification XP, streaks)
/// - `.lastWriteWins`: Most recent timestamp wins (reactions)
/// - `.serverWins`: Always take server value (clips)
/// - `.weightedMerge`: Combine device signals (preferences)
public final class ConflictResolver: ConflictResolverProtocol, @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = ConflictResolver()

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    /// Resolves a conflict between local and remote records using the
    /// appropriate strategy for the table.
    ///
    /// - Parameters:
    ///   - table: The database table name
    ///   - local: The local record as a dictionary
    ///   - remote: The remote record as a dictionary
    /// - Returns: The resolved record with metadata
    public func resolve(
        table: String,
        local: [String: Any],
        remote: [String: Any]
    ) -> ResolvedRecord {
        let strategy = TableConflictMapping.strategy(for: table)

        switch strategy {
        case .union:
            return resolveWithUnion(table: table, local: local, remote: remote)

        case .maxWins:
            return resolveWithMaxWins(table: table, local: local, remote: remote)

        case .lastWriteWins:
            return resolveWithLastWriteWins(local: local, remote: remote)

        case .serverWins:
            return resolveWithServerWins(remote: remote)

        case .weightedMerge:
            return resolveWithWeightedMerge(local: local, remote: remote)
        }
    }

    // MARK: - Strategy Implementations

    /// Union strategy: Merge items, keeping content from both sources.
    /// For list items and badges, we never lose user content.
    private func resolveWithUnion(
        table: String,
        local: [String: Any],
        remote: [String: Any]
    ) -> ResolvedRecord {
        var merged = remote

        // For user_badges, merge badge collections
        if table == "user_badges" {
            // Take max progress and preserve unlock status
            let localProgress = local["progress"] as? Int ?? 0
            let remoteProgress = remote["progress"] as? Int ?? 0
            merged["progress"] = max(localProgress, remoteProgress)

            // If either has unlocked_at, preserve the earlier one
            let localUnlocked = parseDate(local["unlocked_at"])
            let remoteUnlocked = parseDate(remote["unlocked_at"])

            if let local = localUnlocked, let remote = remoteUnlocked {
                // Keep the earlier unlock date
                merged["unlocked_at"] = local < remote
                    ? local.ISO8601Format()
                    : remote.ISO8601Format()
            } else if localUnlocked != nil {
                merged["unlocked_at"] = local["unlocked_at"]
            }
            // else keep remote's unlocked_at (or nil)

            merged["updated_at"] = ISO8601DateFormatter().string(from: Date())

            return ResolvedRecord(
                record: merged,
                strategyUsed: .union,
                wasModified: true,
                source: .merged
            )
        }

        // For lists and list_items, check deleted_at
        // If either is NOT deleted, prefer the non-deleted version
        let localDeleted = local["deleted_at"] != nil && !(local["deleted_at"] is NSNull)
        let remoteDeleted = remote["deleted_at"] != nil && !(remote["deleted_at"] is NSNull)

        if localDeleted && !remoteDeleted {
            // Remote is not deleted, use remote
            return ResolvedRecord(
                record: remote,
                strategyUsed: .union,
                wasModified: false,
                source: .remote
            )
        } else if !localDeleted && remoteDeleted {
            // Local is not deleted, use local
            return ResolvedRecord(
                record: local,
                strategyUsed: .union,
                wasModified: true,
                source: .local
            )
        }

        // Both deleted or both not deleted - use last write wins
        return resolveWithLastWriteWins(local: local, remote: remote)
    }

    /// Max wins strategy: Take maximum values for numeric fields.
    /// Used for gamification where XP/progress should never decrease.
    private func resolveWithMaxWins(
        table: String,
        local: [String: Any],
        remote: [String: Any]
    ) -> ResolvedRecord {
        if table == "user_gamification" {
            return resolveGamification(local: local, remote: remote)
        }

        // Generic max wins for other tables
        var merged = remote

        // Take max of common numeric fields
        let numericFields = ["total_xp", "current_level", "current_streak",
                            "longest_streak", "progress", "count", "score"]

        for field in numericFields {
            if let localVal = local[field] as? Int,
               let remoteVal = remote[field] as? Int {
                merged[field] = max(localVal, remoteVal)
            } else if let localVal = local[field] as? Double,
                      let remoteVal = remote[field] as? Double {
                merged[field] = max(localVal, remoteVal)
            }
        }

        merged["updated_at"] = ISO8601DateFormatter().string(from: Date())

        // Check if merged differs from remote
        let wasModified = recordsAreDifferent(merged, remote)

        return ResolvedRecord(
            record: merged,
            strategyUsed: .maxWins,
            wasModified: wasModified,
            source: wasModified ? .merged : .remote
        )
    }

    /// Gamification-specific merge logic as specified in the plan.
    ///
    /// ```swift
    /// func resolve(local: GamificationState, remote: GamificationState) -> GamificationState {
    ///     return GamificationState(
    ///         userId: local.userId,
    ///         totalXP: max(local.totalXP, remote.totalXP),
    ///         level: calculateLevel(from: max(local.totalXP, remote.totalXP)),
    ///         badges: Set(local.badges).union(Set(remote.badges)).sorted(),
    ///         currentStreak: max(local.currentStreak, remote.currentStreak),
    ///         updatedAt: Date()
    ///     )
    /// }
    /// ```
    private func resolveGamification(
        local: [String: Any],
        remote: [String: Any]
    ) -> ResolvedRecord {
        var merged: [String: Any] = [:]

        // Preserve user_id from local
        merged["user_id"] = local["user_id"] ?? remote["user_id"]

        // XP: max wins
        let localXP = local["total_xp"] as? Int ?? 0
        let remoteXP = remote["total_xp"] as? Int ?? 0
        let maxXP = max(localXP, remoteXP)
        merged["total_xp"] = maxXP

        // Level: recalculated from max XP
        merged["current_level"] = calculateLevel(from: maxXP)

        // Current streak: max wins
        let localStreak = local["current_streak"] as? Int ?? 0
        let remoteStreak = remote["current_streak"] as? Int ?? 0
        merged["current_streak"] = max(localStreak, remoteStreak)

        // Longest streak: max wins
        let localLongest = local["longest_streak"] as? Int ?? 0
        let remoteLongest = remote["longest_streak"] as? Int ?? 0
        merged["longest_streak"] = max(localLongest, remoteLongest)

        // Streak freezes: max wins
        let localFreezes = local["streak_freezes_remaining"] as? Int ?? 0
        let remoteFreezes = remote["streak_freezes_remaining"] as? Int ?? 0
        merged["streak_freezes_remaining"] = max(localFreezes, remoteFreezes)

        // Last activity date: use most recent
        let localActivity = parseDate(local["last_activity_date"])
        let remoteActivity = parseDate(remote["last_activity_date"])
        if let localDate = localActivity, let remoteDate = remoteActivity {
            merged["last_activity_date"] = (localDate > remoteDate ? localDate : remoteDate).ISO8601Format()
        } else if let localDate = localActivity {
            merged["last_activity_date"] = localDate.ISO8601Format()
        } else if let remoteDate = remoteActivity {
            merged["last_activity_date"] = remoteDate.ISO8601Format()
        }

        // Updated timestamp
        merged["updated_at"] = ISO8601DateFormatter().string(from: Date())

        return ResolvedRecord(
            record: merged,
            strategyUsed: .maxWins,
            wasModified: true,
            source: .merged
        )
    }

    /// Calculates level from total XP using the same formula as GamificationService.
    ///
    /// Level thresholds:
    /// - Level 1: 0 XP
    /// - Level 2-5: (level - 1) * 100
    /// - Level 6-10: 500 + (level - 5) * 300
    /// - Level 11-15: 2000 + (level - 10) * 600
    /// - Level 16-20: 5000 + (level - 15) * 1000
    /// - Level 21-25: 10000 + (level - 20) * 2000
    /// - Level 26-30: 20000 + (level - 25) * 4000
    /// - Level 31-40: 40000 + (level - 30) * 4000
    /// - Level 41+: 80000 + (level - 40) * 5000
    public func calculateLevel(from xp: Int) -> Int {
        var level = 1
        while levelThreshold(for: level + 1) <= xp && level < 50 {
            level += 1
        }
        return level
    }

    private func levelThreshold(for level: Int) -> Int {
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

    /// Last write wins strategy: Most recent timestamp wins.
    /// Used for reactions where user's latest intent should prevail.
    private func resolveWithLastWriteWins(
        local: [String: Any],
        remote: [String: Any]
    ) -> ResolvedRecord {
        let localDate = parseDate(local["updated_at"])
        let remoteDate = parseDate(remote["updated_at"])

        // If we have both dates, compare them
        if let localDate = localDate, let remoteDate = remoteDate {
            if localDate > remoteDate {
                return ResolvedRecord(
                    record: local,
                    strategyUsed: .lastWriteWins,
                    wasModified: true,
                    source: .local
                )
            } else {
                return ResolvedRecord(
                    record: remote,
                    strategyUsed: .lastWriteWins,
                    wasModified: false,
                    source: .remote
                )
            }
        }

        // If only one has a date, prefer the one with a date
        if localDate != nil && remoteDate == nil {
            return ResolvedRecord(
                record: local,
                strategyUsed: .lastWriteWins,
                wasModified: true,
                source: .local
            )
        }

        // Default to remote if no dates or remote has date
        return ResolvedRecord(
            record: remote,
            strategyUsed: .lastWriteWins,
            wasModified: false,
            source: .remote
        )
    }

    /// Server wins strategy: Always take the remote/server value.
    /// Used for clips where content is authoritative.
    private func resolveWithServerWins(remote: [String: Any]) -> ResolvedRecord {
        return ResolvedRecord(
            record: remote,
            strategyUsed: .serverWins,
            wasModified: false,
            source: .remote
        )
    }

    /// Weighted merge strategy: Combine signals from multiple devices.
    /// Used for unified_user_preferences.
    ///
    /// Merges scores additively with time weighting:
    /// - More recent device gets 60% weight
    /// - Older device gets 40% weight
    private func resolveWithWeightedMerge(
        local: [String: Any],
        remote: [String: Any]
    ) -> ResolvedRecord {
        var merged = remote

        // Determine which is more recent
        let localDate = parseDate(local["updated_at"]) ?? Date.distantPast
        let remoteDate = parseDate(remote["updated_at"]) ?? Date.distantPast
        let localIsNewer = localDate > remoteDate

        let localWeight: Double = localIsNewer ? 0.6 : 0.4
        let remoteWeight: Double = localIsNewer ? 0.4 : 0.6

        // Weighted merge for main score
        if let localScore = local["score"] as? Double,
           let remoteScore = remote["score"] as? Double {
            merged["score"] = (localScore * localWeight) + (remoteScore * remoteWeight)
        }

        // Max for individual source scores (they represent cumulative engagement)
        let sourceScoreFields = [
            "score_from_clips",
            "score_from_discovery",
            "score_from_search",
            "score_from_ai",
            "score_from_lists"
        ]

        for field in sourceScoreFields {
            if let localVal = local[field] as? Double,
               let remoteVal = remote[field] as? Double {
                merged[field] = max(localVal, remoteVal)
            }
        }

        // Sum interaction counts
        if let localCount = local["interaction_count"] as? Int,
           let remoteCount = remote["interaction_count"] as? Int {
            // Avoid double counting - take max if they share history
            merged["interaction_count"] = max(localCount, remoteCount)
        }

        // Use most recent interaction timestamp
        let localInteraction = parseDate(local["last_interaction_at"])
        let remoteInteraction = parseDate(remote["last_interaction_at"])
        if let li = localInteraction, let ri = remoteInteraction {
            merged["last_interaction_at"] = (li > ri ? li : ri).ISO8601Format()
        }

        merged["updated_at"] = ISO8601DateFormatter().string(from: Date())

        return ResolvedRecord(
            record: merged,
            strategyUsed: .weightedMerge,
            wasModified: true,
            source: .merged
        )
    }

    // MARK: - Helpers

    /// Parses a date from various formats commonly used in the database.
    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }

        // Try ISO8601 first
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) {
            return date
        }

        // Try alternative format
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: string)
    }

    /// Compares two records to check if they differ.
    /// Ignores updated_at field since it's always modified.
    private func recordsAreDifferent(_ record1: [String: Any], _ record2: [String: Any]) -> Bool {
        // Compare relevant numeric fields that might differ
        let numericFields = ["total_xp", "current_level", "current_streak",
                            "longest_streak", "progress", "count", "score"]

        for field in numericFields {
            if let val1 = record1[field] as? Int,
               let val2 = record2[field] as? Int,
               val1 != val2 {
                return true
            }
            if let val1 = record1[field] as? Double,
               let val2 = record2[field] as? Double,
               abs(val1 - val2) > 0.0001 {
                return true
            }
        }

        return false
    }
}

// MARK: - Convenience Extensions

extension ConflictResolver {
    /// Resolves a list of local badges with remote badges using union semantics.
    /// Returns the merged set of badge IDs.
    public func mergeBadges(
        localBadgeIds: [String],
        remoteBadgeIds: [String]
    ) -> [String] {
        let localSet = Set(localBadgeIds)
        let remoteSet = Set(remoteBadgeIds)
        return Array(localSet.union(remoteSet)).sorted()
    }

    /// Quick check if a record needs resolution (has both local and remote versions).
    public func needsResolution(local: [String: Any]?, remote: [String: Any]?) -> Bool {
        return local != nil && remote != nil
    }
}
