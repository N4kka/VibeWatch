import XCTest
@testable import VibeWatchApp

/// Unit tests for the ConflictResolver and ConflictStrategy system.
/// Tests all 5 conflict resolution strategies and the gamification merge logic.
final class ConflictResolverTests: XCTestCase {

    var resolver: ConflictResolver!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        resolver = ConflictResolver()
    }

    override func tearDown() {
        resolver = nil
        super.tearDown()
    }

    // MARK: - ConflictStrategy Enum Tests

    func testConflictStrategyDescription() {
        XCTAssertEqual(ConflictStrategy.union.description, "Merge items from both sources (never lose content)")
        XCTAssertEqual(ConflictStrategy.maxWins.description, "Take maximum value (XP/progress never decreases)")
        XCTAssertEqual(ConflictStrategy.lastWriteWins.description, "Most recent timestamp wins (latest user intent)")
        XCTAssertEqual(ConflictStrategy.serverWins.description, "Server is authoritative (content sync)")
        XCTAssertEqual(ConflictStrategy.weightedMerge.description, "Combine signals from multiple devices")

        print("ConflictStrategy description tests passed")
    }

    // MARK: - Table Strategy Mapping Tests

    func testTableToStrategyMapping() {
        // Lists and list_items use union
        XCTAssertEqual(TableConflictMapping.strategy(for: "lists"), .union)
        XCTAssertEqual(TableConflictMapping.strategy(for: "list_items"), .union)

        // user_gamification uses maxWins
        XCTAssertEqual(TableConflictMapping.strategy(for: "user_gamification"), .maxWins)

        // user_badges uses union
        XCTAssertEqual(TableConflictMapping.strategy(for: "user_badges"), .union)

        // movie_reactions uses lastWriteWins
        XCTAssertEqual(TableConflictMapping.strategy(for: "movie_reactions"), .lastWriteWins)

        // unified_user_preferences uses weightedMerge
        XCTAssertEqual(TableConflictMapping.strategy(for: "unified_user_preferences"), .weightedMerge)

        // clips uses serverWins
        XCTAssertEqual(TableConflictMapping.strategy(for: "clips"), .serverWins)

        // Unknown tables default to lastWriteWins
        XCTAssertEqual(TableConflictMapping.strategy(for: "unknown_table"), .lastWriteWins)

        print("Table to strategy mapping tests passed")
    }

    func testAllMappingsArePresent() {
        let mappings = TableConflictMapping.allMappings
        XCTAssertEqual(mappings.count, 7, "Should have 7 table mappings")

        let tableNames = mappings.map { $0.table }
        XCTAssertTrue(tableNames.contains("lists"))
        XCTAssertTrue(tableNames.contains("list_items"))
        XCTAssertTrue(tableNames.contains("user_gamification"))
        XCTAssertTrue(tableNames.contains("user_badges"))
        XCTAssertTrue(tableNames.contains("movie_reactions"))
        XCTAssertTrue(tableNames.contains("unified_user_preferences"))
        XCTAssertTrue(tableNames.contains("clips"))

        print("All mappings present test passed")
    }

    // MARK: - Union Strategy Tests

    func testUnionStrategy_ListItems_PreservesNonDeleted() {
        // Local is not deleted, remote is deleted
        let local: [String: Any] = [
            "id": "item-1",
            "media_id": 123,
            "deleted_at": NSNull(),
            "updated_at": "2024-01-01T10:00:00Z"
        ]
        let remote: [String: Any] = [
            "id": "item-1",
            "media_id": 123,
            "deleted_at": "2024-01-02T10:00:00Z",
            "updated_at": "2024-01-02T10:00:00Z"
        ]

        let result = resolver.resolve(table: "list_items", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .union)
        XCTAssertEqual(result.source, .local, "Should prefer non-deleted local record")
        XCTAssertTrue(result.wasModified)
        XCTAssertTrue(result.record["deleted_at"] is NSNull, "Local should not be deleted")

        print("Union strategy preserves non-deleted test passed")
    }

    func testUnionStrategy_Badges_MergesProgress() {
        let local: [String: Any] = [
            "id": "user1_badge1",
            "badge_id": "watch_10",
            "progress": 8,
            "unlocked_at": NSNull(),
            "updated_at": "2024-01-01T10:00:00Z"
        ]
        let remote: [String: Any] = [
            "id": "user1_badge1",
            "badge_id": "watch_10",
            "progress": 5,
            "unlocked_at": "2024-01-02T12:00:00Z",  // Already unlocked remotely
            "updated_at": "2024-01-02T10:00:00Z"
        ]

        let result = resolver.resolve(table: "user_badges", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .union)
        XCTAssertEqual(result.record["progress"] as? Int, 8, "Should take max progress")
        XCTAssertNotNil(result.record["unlocked_at"], "Should preserve unlock status")
        XCTAssertEqual(result.source, .merged)

        print("Union strategy badges merge test passed")
    }

    // MARK: - MaxWins Strategy Tests

    func testMaxWinsStrategy_Gamification() {
        let local: [String: Any] = [
            "user_id": "user-123",
            "total_xp": 500,
            "current_level": 3,
            "current_streak": 7,
            "longest_streak": 10,
            "streak_freezes_remaining": 2,
            "last_activity_date": "2024-01-01T10:00:00Z",
            "updated_at": "2024-01-01T10:00:00Z"
        ]
        let remote: [String: Any] = [
            "user_id": "user-123",
            "total_xp": 800,      // Higher remotely
            "current_level": 4,    // Higher remotely
            "current_streak": 3,   // Lower remotely
            "longest_streak": 15,  // Higher remotely
            "streak_freezes_remaining": 1,  // Lower remotely
            "last_activity_date": "2024-01-02T10:00:00Z",  // More recent
            "updated_at": "2024-01-02T10:00:00Z"
        ]

        let result = resolver.resolve(table: "user_gamification", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .maxWins)
        XCTAssertEqual(result.record["total_xp"] as? Int, 800, "Should take max XP")
        XCTAssertEqual(result.record["current_streak"] as? Int, 7, "Should take max streak")
        XCTAssertEqual(result.record["longest_streak"] as? Int, 15, "Should take max longest streak")
        XCTAssertEqual(result.record["streak_freezes_remaining"] as? Int, 2, "Should take max freezes")
        XCTAssertEqual(result.source, .merged)

        print("MaxWins strategy gamification test passed")
    }

    func testMaxWinsStrategy_GamificationLevelRecalculation() {
        // XP: 1500 should be level 6 (threshold: 500 + (6-5)*300 = 800)
        // Level 5 threshold: 400, Level 6 threshold: 800, Level 7 threshold: 1100
        let local: [String: Any] = [
            "user_id": "user-123",
            "total_xp": 1500,
            "current_level": 5,  // Incorrectly stored level
            "current_streak": 1,
            "longest_streak": 1,
            "updated_at": "2024-01-01T10:00:00Z"
        ]
        let remote: [String: Any] = [
            "user_id": "user-123",
            "total_xp": 1200,
            "current_level": 6,
            "current_streak": 1,
            "longest_streak": 1,
            "updated_at": "2024-01-02T10:00:00Z"
        ]

        let result = resolver.resolve(table: "user_gamification", local: local, remote: remote)

        // Max XP is 1500, level should be recalculated
        XCTAssertEqual(result.record["total_xp"] as? Int, 1500)

        // Level 8 threshold is 500 + 3*300 = 1400, Level 9 is 500 + 4*300 = 1700
        // So 1500 XP = Level 8
        let expectedLevel = resolver.calculateLevel(from: 1500)
        XCTAssertEqual(result.record["current_level"] as? Int, expectedLevel)

        print("MaxWins strategy level recalculation test passed")
    }

    func testGamificationMergeMatchesPlanSpec() {
        // Test the exact merge logic from the plan:
        // totalXP: max(local.totalXP, remote.totalXP)
        // level: calculateLevel(from: max XP)
        // currentStreak: max(local.currentStreak, remote.currentStreak)

        let local: [String: Any] = [
            "user_id": "user-abc",
            "total_xp": 2500,
            "current_level": 11,
            "current_streak": 14,
            "longest_streak": 20,
            "streak_freezes_remaining": 3,
            "last_activity_date": "2024-01-15T08:00:00Z",
            "updated_at": "2024-01-15T08:00:00Z"
        ]
        let remote: [String: Any] = [
            "user_id": "user-abc",
            "total_xp": 3000,
            "current_level": 12,
            "current_streak": 5,
            "longest_streak": 14,
            "streak_freezes_remaining": 0,
            "last_activity_date": "2024-01-20T10:00:00Z",
            "updated_at": "2024-01-20T10:00:00Z"
        ]

        let result = resolver.resolve(table: "user_gamification", local: local, remote: remote)

        // Verify merge logic from plan
        XCTAssertEqual(result.record["user_id"] as? String, "user-abc")
        XCTAssertEqual(result.record["total_xp"] as? Int, 3000, "max(2500, 3000) = 3000")

        let expectedLevel = resolver.calculateLevel(from: 3000)
        XCTAssertEqual(result.record["current_level"] as? Int, expectedLevel, "Level recalculated from max XP")

        XCTAssertEqual(result.record["current_streak"] as? Int, 14, "max(14, 5) = 14")
        XCTAssertEqual(result.record["longest_streak"] as? Int, 20, "max(20, 14) = 20")
        XCTAssertEqual(result.record["streak_freezes_remaining"] as? Int, 3, "max(3, 0) = 3")

        // Last activity date should be the most recent
        let lastActivity = result.record["last_activity_date"] as? String
        XCTAssertNotNil(lastActivity)
        XCTAssertTrue(lastActivity!.contains("2024-01-20"), "Should use more recent activity date")

        print("Gamification merge matches plan spec test passed")
    }

    // MARK: - LastWriteWins Strategy Tests

    func testLastWriteWinsStrategy_LocalNewer() {
        let local: [String: Any] = [
            "id": "reaction-1",
            "media_id": 123,
            "reaction_type": "love",
            "updated_at": "2024-01-02T15:00:00Z"  // Newer
        ]
        let remote: [String: Any] = [
            "id": "reaction-1",
            "media_id": 123,
            "reaction_type": "like",
            "updated_at": "2024-01-01T10:00:00Z"  // Older
        ]

        let result = resolver.resolve(table: "movie_reactions", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .lastWriteWins)
        XCTAssertEqual(result.source, .local)
        XCTAssertTrue(result.wasModified)
        XCTAssertEqual(result.record["reaction_type"] as? String, "love")

        print("LastWriteWins local newer test passed")
    }

    func testLastWriteWinsStrategy_RemoteNewer() {
        let local: [String: Any] = [
            "id": "reaction-1",
            "media_id": 123,
            "reaction_type": "like",
            "updated_at": "2024-01-01T10:00:00Z"  // Older
        ]
        let remote: [String: Any] = [
            "id": "reaction-1",
            "media_id": 123,
            "reaction_type": "love",
            "updated_at": "2024-01-02T15:00:00Z"  // Newer
        ]

        let result = resolver.resolve(table: "movie_reactions", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .lastWriteWins)
        XCTAssertEqual(result.source, .remote)
        XCTAssertFalse(result.wasModified)
        XCTAssertEqual(result.record["reaction_type"] as? String, "love")

        print("LastWriteWins remote newer test passed")
    }

    func testLastWriteWinsStrategy_MissingTimestamps() {
        // Only local has timestamp
        let local: [String: Any] = [
            "id": "reaction-1",
            "reaction_type": "like",
            "updated_at": "2024-01-01T10:00:00Z"
        ]
        let remote: [String: Any] = [
            "id": "reaction-1",
            "reaction_type": "love"
            // No updated_at
        ]

        let result = resolver.resolve(table: "movie_reactions", local: local, remote: remote)

        XCTAssertEqual(result.source, .local, "Should prefer record with timestamp")
        XCTAssertTrue(result.wasModified)

        print("LastWriteWins missing timestamps test passed")
    }

    // MARK: - ServerWins Strategy Tests

    func testServerWinsStrategy_AlwaysTakesRemote() {
        let local: [String: Any] = [
            "id": "clip-1",
            "title": "Local Title",
            "duration": 30,
            "updated_at": "2024-01-02T15:00:00Z"  // Even if newer
        ]
        let remote: [String: Any] = [
            "id": "clip-1",
            "title": "Server Title",
            "duration": 45,
            "updated_at": "2024-01-01T10:00:00Z"  // Even if older
        ]

        let result = resolver.resolve(table: "clips", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .serverWins)
        XCTAssertEqual(result.source, .remote)
        XCTAssertFalse(result.wasModified)
        XCTAssertEqual(result.record["title"] as? String, "Server Title")
        XCTAssertEqual(result.record["duration"] as? Int, 45)

        print("ServerWins always takes remote test passed")
    }

    // MARK: - WeightedMerge Strategy Tests

    func testWeightedMergeStrategy_CombinesScores() {
        let local: [String: Any] = [
            "id": "pref-1",
            "preference_id": "genre-action",
            "score": 0.8,
            "score_from_clips": 0.5,
            "score_from_discovery": 0.3,
            "score_from_search": 0.2,
            "score_from_ai": 0.0,
            "score_from_lists": 0.1,
            "interaction_count": 10,
            "last_interaction_at": "2024-01-02T15:00:00Z",  // Newer
            "updated_at": "2024-01-02T15:00:00Z"
        ]
        let remote: [String: Any] = [
            "id": "pref-1",
            "preference_id": "genre-action",
            "score": 0.6,
            "score_from_clips": 0.3,
            "score_from_discovery": 0.4,
            "score_from_search": 0.1,
            "score_from_ai": 0.2,
            "score_from_lists": 0.0,
            "interaction_count": 5,
            "last_interaction_at": "2024-01-01T10:00:00Z",  // Older
            "updated_at": "2024-01-01T10:00:00Z"
        ]

        let result = resolver.resolve(table: "unified_user_preferences", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .weightedMerge)
        XCTAssertEqual(result.source, .merged)
        XCTAssertTrue(result.wasModified)

        // Weighted score: local is newer so 60% local, 40% remote
        // Expected: 0.8 * 0.6 + 0.6 * 0.4 = 0.48 + 0.24 = 0.72
        let mergedScore = result.record["score"] as? Double ?? 0
        XCTAssertEqual(mergedScore, 0.72, accuracy: 0.01)

        // Source scores should be max
        XCTAssertEqual(result.record["score_from_clips"] as? Double, 0.5)
        XCTAssertEqual(result.record["score_from_discovery"] as? Double, 0.4)
        XCTAssertEqual(result.record["score_from_search"] as? Double, 0.2)
        XCTAssertEqual(result.record["score_from_ai"] as? Double, 0.2)
        XCTAssertEqual(result.record["score_from_lists"] as? Double, 0.1)

        // Interaction count should be max
        XCTAssertEqual(result.record["interaction_count"] as? Int, 10)

        print("WeightedMerge combines scores test passed")
    }

    func testWeightedMergeStrategy_RemoteNewer() {
        let local: [String: Any] = [
            "id": "pref-1",
            "score": 0.8,
            "updated_at": "2024-01-01T10:00:00Z"  // Older
        ]
        let remote: [String: Any] = [
            "id": "pref-1",
            "score": 0.6,
            "updated_at": "2024-01-02T15:00:00Z"  // Newer
        ]

        let result = resolver.resolve(table: "unified_user_preferences", local: local, remote: remote)

        // Remote is newer so 60% remote, 40% local
        // Expected: 0.8 * 0.4 + 0.6 * 0.6 = 0.32 + 0.36 = 0.68
        let mergedScore = result.record["score"] as? Double ?? 0
        XCTAssertEqual(mergedScore, 0.68, accuracy: 0.01)

        print("WeightedMerge remote newer test passed")
    }

    // MARK: - Level Calculation Tests

    func testLevelCalculation() {
        // La curva è CUMULATIVA: `GamificationLeveling.threshold(for:)` è l'XP totale per
        // RAGGIUNGERE quel livello (L6 = 500 + 1×300 = 800, non 500). Questo test assumeva
        // che la soglia coincidesse col numero tondo ed era rosso da prima di SPEC v3;
        // cambiarlo nel codice sposterebbe il livello di ogni utente (la stessa curva guida
        // GamificationService e LevelProgressView), quindi la correzione sta QUI.
        XCTAssertEqual(resolver.calculateLevel(from: 0), 1)      // L1 parte da 0
        XCTAssertEqual(resolver.calculateLevel(from: 99), 1)     // sotto la soglia di L2
        XCTAssertEqual(resolver.calculateLevel(from: 100), 2)    // L2 = 100
        XCTAssertEqual(resolver.calculateLevel(from: 200), 3)    // L3 = 200
        XCTAssertEqual(resolver.calculateLevel(from: 400), 5)    // L5 = 400
        XCTAssertEqual(resolver.calculateLevel(from: 500), 5)    // L6 è a 800: 500 resta L5
        XCTAssertEqual(resolver.calculateLevel(from: 799), 5)    // bordo sotto L6
        XCTAssertEqual(resolver.calculateLevel(from: 800), 6)    // L6 = 500 + 300
        XCTAssertEqual(resolver.calculateLevel(from: 2599), 10)  // bordo sotto L11
        XCTAssertEqual(resolver.calculateLevel(from: 2600), 11)  // L11 = 2000 + 600
        XCTAssertEqual(resolver.calculateLevel(from: 6000), 16)  // L16 = 5000 + 1000
        XCTAssertEqual(resolver.calculateLevel(from: 12000), 21) // L21 = 10000 + 2000
        XCTAssertEqual(resolver.calculateLevel(from: 24000), 26) // L26 = 20000 + 4000
        XCTAssertEqual(resolver.calculateLevel(from: 44000), 31) // L31 = 40000 + 4000
        XCTAssertEqual(resolver.calculateLevel(from: 85000), 41) // L41 = 80000 + 5000

        // La sorgente unica e il delegato devono restare la stessa curva.
        XCTAssertEqual(resolver.calculateLevel(from: 800), GamificationLeveling.level(forTotalXP: 800))

        print("Level calculation test passed")
    }

    // MARK: - Badge Merge Tests

    func testMergeBadges() {
        let localBadges = ["watch_1", "watch_10", "streak_3"]
        let remoteBadges = ["watch_1", "streak_7", "like_1"]

        let merged = resolver.mergeBadges(
            localBadgeIds: localBadges,
            remoteBadgeIds: remoteBadges
        )

        XCTAssertEqual(merged.count, 5, "Should have 5 unique badges")
        XCTAssertTrue(merged.contains("watch_1"))
        XCTAssertTrue(merged.contains("watch_10"))
        XCTAssertTrue(merged.contains("streak_3"))
        XCTAssertTrue(merged.contains("streak_7"))
        XCTAssertTrue(merged.contains("like_1"))

        // Should be sorted
        XCTAssertEqual(merged, merged.sorted())

        print("Merge badges test passed")
    }

    // MARK: - Helper Tests

    func testNeedsResolution() {
        XCTAssertTrue(resolver.needsResolution(
            local: ["id": "1"],
            remote: ["id": "1"]
        ))
        XCTAssertFalse(resolver.needsResolution(
            local: nil,
            remote: ["id": "1"]
        ))
        XCTAssertFalse(resolver.needsResolution(
            local: ["id": "1"],
            remote: nil
        ))
        XCTAssertFalse(resolver.needsResolution(
            local: nil,
            remote: nil
        ))

        print("Needs resolution test passed")
    }

    // MARK: - ResolvedRecord Tests

    func testResolvedRecordStructure() {
        let record: [String: Any] = ["id": "test", "value": 42]
        let resolved = ResolvedRecord(
            record: record,
            strategyUsed: .maxWins,
            wasModified: true,
            source: .merged
        )

        XCTAssertEqual(resolved.strategyUsed, .maxWins)
        XCTAssertTrue(resolved.wasModified)
        XCTAssertEqual(resolved.source, .merged)
        XCTAssertEqual(resolved.record["id"] as? String, "test")
        XCTAssertEqual(resolved.record["value"] as? Int, 42)

        print("ResolvedRecord structure test passed")
    }

    func testResolvedRecordSource() {
        XCTAssertEqual(ResolvedRecord.RecordSource.local.rawValue, "local")
        XCTAssertEqual(ResolvedRecord.RecordSource.remote.rawValue, "remote")
        XCTAssertEqual(ResolvedRecord.RecordSource.merged.rawValue, "merged")

        print("ResolvedRecord source test passed")
    }
}

// MARK: - Integration Tests

extension ConflictResolverTests {

    func testFullConflictResolutionFlow() {
        print("Starting full conflict resolution flow test...")

        // Simulate a complete sync scenario
        let tables = ["lists", "user_gamification", "movie_reactions", "clips", "unified_user_preferences"]

        for table in tables {
            let local: [String: Any] = [
                "id": "test-\(table)",
                "updated_at": "2024-01-01T10:00:00Z"
            ]
            let remote: [String: Any] = [
                "id": "test-\(table)",
                "updated_at": "2024-01-02T10:00:00Z"
            ]

            let result = resolver.resolve(table: table, local: local, remote: remote)

            XCTAssertNotNil(result.record)
            XCTAssertEqual(result.strategyUsed, TableConflictMapping.strategy(for: table))
            print("  - \(table): \(result.strategyUsed.rawValue)")
        }

        print("Full conflict resolution flow test passed")
    }

    func testEdgeCases() {
        // Empty records
        let emptyLocal: [String: Any] = [:]
        let emptyRemote: [String: Any] = [:]

        let result = resolver.resolve(table: "clips", local: emptyLocal, remote: emptyRemote)
        XCTAssertNotNil(result.record)

        // Records with NSNull values
        let localWithNull: [String: Any] = [
            "id": "test",
            "value": NSNull()
        ]
        let remoteWithValue: [String: Any] = [
            "id": "test",
            "value": 42
        ]

        let result2 = resolver.resolve(table: "clips", local: localWithNull, remote: remoteWithValue)
        XCTAssertEqual(result2.record["value"] as? Int, 42)

        print("Edge cases test passed")
    }
}
