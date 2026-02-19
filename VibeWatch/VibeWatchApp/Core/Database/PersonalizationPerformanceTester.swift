import Foundation

/// Performance testing suite for user preferences & personalization system
/// Tests query performance, indexing efficiency, and scalability
class PersonalizationPerformanceTester {

    private let db: SQLiteService
    private var testResults: [TestResult] = []

    struct TestResult {
        let name: String
        let duration: TimeInterval
        let recordCount: Int
        let passed: Bool
        let targetMs: Double
        let details: String

        var performanceRating: String {
            let percentage = (duration * 1000) / targetMs * 100
            if percentage <= 50 { return "Excellent" }
            if percentage <= 80 { return "Good" }
            if percentage <= 100 { return "Acceptable" }
            return "Needs Optimization"
        }
    }

    init(db: SQLiteService = .shared) {
        self.db = db
    }

    // MARK: - Main Test Suite

    func runFullTestSuite() async {
        Logger.info("=============================================================")
        Logger.info("🚀 Starting User Preferences Performance Test Suite")
        Logger.info("=============================================================")

        testResults.removeAll()

        // Generate test data first
        await generateTestData()

        // Run performance tests
        await testTopGenresQuery()
        await testPersonalizedCarouselQuery()
        await testPreferenceAggregationQuery()
        await testPendingSyncQuery()
        await testSearchHistoryQuery()
        await testDiscoveryInteractionsQuery()
        await testAIConversationQuery()
        await testUnifiedPreferenceUpdate()
        await testBatchInsertPerformance()
        await testComplexJoinQuery()

        // Print results
        printTestResults()
    }

    // MARK: - Test Data Generation

    func generateTestData() async {
        Logger.info("\n📊 Generating test data...")

        let startTime = CFAbsoluteTimeGetCurrent()
        let testUserId = "test-user-performance-\(UUID().uuidString)"
        let deviceId = "test-device-\(UUID().uuidString)"

        // Generate 10,000 preference records
        Logger.info("Creating 10,000 preference records...")
        var preferences: [[String: Any]] = []

        let categories = ["genre", "actor", "director", "mood", "keyword"]
        let sampleGenres = ["Action", "Drama", "Comedy", "Sci-Fi", "Thriller", "Horror", "Romance", "Adventure"]
        let sampleActors = ["Tom Hanks", "Meryl Streep", "Denzel Washington", "Scarlett Johansson", "Leonardo DiCaprio"]
        let sampleMoods = ["Exciting", "Emotional", "Funny", "Suspenseful", "Inspiring"]

        for i in 0..<10000 {
            let category = categories[i % categories.count]
            var name = ""
            let prefId = "\(category)-\(i)"

            switch category {
            case "genre":
                name = sampleGenres[i % sampleGenres.count]
            case "actor":
                name = sampleActors[i % sampleActors.count]
            case "mood":
                name = sampleMoods[i % sampleMoods.count]
            default:
                name = "Item \(i)"
            }

            let score = Double.random(in: 0.1...10.0)
            let interactionCount = Int.random(in: 1...50)
            let now = ISO8601DateFormatter().string(from: Date())

            preferences.append([
                "id": db.generateUUID(),
                "user_id": testUserId,
                "device_id": deviceId,
                "preference_category": category,
                "preference_id": prefId,
                "preference_name": name,
                "score": score,
                "score_from_clips": score * 0.4,
                "score_from_discovery": score * 0.3,
                "score_from_search": score * 0.2,
                "score_from_ai": score * 0.1,
                "score_from_lists": 0.0,
                "interaction_count": interactionCount,
                "last_interaction_at": now,
                "created_at": now,
                "updated_at": now
            ])
        }

        // Batch insert
        for chunk in preferences.chunked(into: 100) {
            try? await db.upsert(table: "unified_user_preferences", rows: chunk)
        }

        // Generate 5,000 discovery interactions
        Logger.info("Creating 5,000 discovery interactions...")
        var interactions: [[String: Any]] = []

        let carouselTypes = ["daily_mix", "trending_genre", "because_you_liked", "popular_now", "new_releases"]
        let interactionTypes = ["view", "click", "add_to_list", "like"]
        let mediaTypes = ["movie", "tv"]

        for i in 0..<5000 {
            let now = ISO8601DateFormatter().string(from: Date())

            interactions.append([
                "id": db.generateUUID(),
                "user_id": testUserId,
                "device_id": deviceId,
                "media_id": Int.random(in: 1000...99999),
                "media_type": mediaTypes[i % mediaTypes.count],
                "carousel_type": carouselTypes[i % carouselTypes.count],
                "interaction_type": interactionTypes[i % interactionTypes.count],
                "interacted_at": now,
                "session_duration": Int.random(in: 5...300),
                "filter_active": i % 3 == 0 ? 1 : 0
            ])
        }

        for chunk in interactions.chunked(into: 100) {
            try? await db.upsert(table: "user_discovery_interactions", rows: chunk)
        }

        // Generate 1,000 search queries
        Logger.info("Creating 1,000 search queries...")
        var searches: [[String: Any]] = []

        let sampleQueries = ["action movies", "sci-fi", "comedy 2024", "thriller", "tom hanks", "oscar winners"]

        for i in 0..<1000 {
            let now = ISO8601DateFormatter().string(from: Date())

            searches.append([
                "id": db.generateUUID(),
                "user_id": testUserId,
                "device_id": deviceId,
                "query": sampleQueries[i % sampleQueries.count],
                "media_type": i % 2 == 0 ? "movie" : "tv",
                "result_count": Int.random(in: 5...50),
                "searched_at": now,
                "relevance_score": Double.random(in: 0.5...1.0)
            ])
        }

        for chunk in searches.chunked(into: 100) {
            try? await db.upsert(table: "user_search_history", rows: chunk)
        }

        // Generate 500 AI conversations
        Logger.info("Creating 500 AI conversations...")
        var conversations: [[String: Any]] = []

        let sessionId = "test-session-\(UUID().uuidString)"
        let messageTypes = ["user", "assistant"]
        let queryTypes = ["specific", "recommendation", "comparison", "general"]

        for i in 0..<500 {
            let now = ISO8601DateFormatter().string(from: Date())

            conversations.append([
                "id": db.generateUUID(),
                "user_id": testUserId,
                "device_id": deviceId,
                "session_id": sessionId,
                "message_type": messageTypes[i % messageTypes.count],
                "content": "Test message \(i)",
                "query_type": queryTypes[i % queryTypes.count],
                "tokens_used": Int.random(in: 50...500),
                "created_at": now
            ])
        }

        for chunk in conversations.chunked(into: 100) {
            try? await db.upsert(table: "ai_conversation_history", rows: chunk)
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        Logger.info("✅ Test data generated in \(String(format: "%.2f", duration))s")
        Logger.info("   - 10,000 preferences")
        Logger.info("   - 5,000 interactions")
        Logger.info("   - 1,000 searches")
        Logger.info("   - 500 AI messages")
    }

    // MARK: - Performance Tests

    func testTopGenresQuery() async {
        let testName = "Get Top 5 Genres"
        let targetMs = 50.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let results: [[String: Any]] = try await db.queryRaw("""
                SELECT preference_id, preference_name, score, interaction_count
                FROM unified_user_preferences
                WHERE preference_category = 'genre'
                ORDER BY score DESC
                LIMIT 5
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: results.count,
                passed: passed,
                targetMs: targetMs,
                details: "Retrieved top genres with scores"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testPersonalizedCarouselQuery() async {
        let testName = "Get Personalized Carousel Content"
        let targetMs = 50.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let results: [[String: Any]] = try await db.queryRaw("""
                SELECT carousel_type, media_id, media_type, score, reason
                FROM personalized_discovery
                WHERE carousel_type = 'trending_genre'
                ORDER BY position ASC
                LIMIT 20
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: results.count,
                passed: passed,
                targetMs: targetMs,
                details: "Retrieved carousel content"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testPreferenceAggregationQuery() async {
        let testName = "Aggregate Preference Scores by Source"
        let targetMs = 50.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let results: [[String: Any]] = try await db.queryRaw("""
                SELECT
                    preference_category,
                    COUNT(*) as total_count,
                    SUM(score) as total_score,
                    AVG(score) as avg_score,
                    SUM(score_from_clips) as total_from_clips,
                    SUM(score_from_discovery) as total_from_discovery,
                    SUM(score_from_search) as total_from_search,
                    SUM(score_from_ai) as total_from_ai
                FROM unified_user_preferences
                GROUP BY preference_category
                ORDER BY total_score DESC
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: results.count,
                passed: passed,
                targetMs: targetMs,
                details: "Aggregated scores across sources"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testPendingSyncQuery() async {
        let testName = "Find Pending Sync Operations"
        let targetMs = 30.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let results: [[String: Any]] = try await db.queryRaw("""
                SELECT id, user_id, preference_category, updated_at
                FROM unified_user_preferences
                WHERE synced_at IS NULL
                ORDER BY updated_at DESC
                LIMIT 100
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: results.count,
                passed: passed,
                targetMs: targetMs,
                details: "Found unsynced preferences"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testSearchHistoryQuery() async {
        let testName = "Get Recent Search History"
        let targetMs = 40.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let results: [[String: Any]] = try await db.queryRaw("""
                SELECT query, media_type, result_count, searched_at, relevance_score
                FROM user_search_history
                ORDER BY searched_at DESC
                LIMIT 20
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: results.count,
                passed: passed,
                targetMs: targetMs,
                details: "Retrieved recent searches"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testDiscoveryInteractionsQuery() async {
        let testName = "Get Discovery Interactions by Carousel"
        let targetMs = 50.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let results: [[String: Any]] = try await db.queryRaw("""
                SELECT carousel_type, interaction_type, COUNT(*) as count
                FROM user_discovery_interactions
                GROUP BY carousel_type, interaction_type
                ORDER BY count DESC
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: results.count,
                passed: passed,
                targetMs: targetMs,
                details: "Grouped interactions by type"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testAIConversationQuery() async {
        let testName = "Get AI Conversation History"
        let targetMs = 40.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let results: [[String: Any]] = try await db.queryRaw("""
                SELECT session_id, message_type, content, query_type, created_at
                FROM ai_conversation_history
                ORDER BY created_at DESC
                LIMIT 50
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: results.count,
                passed: passed,
                targetMs: targetMs,
                details: "Retrieved conversation history"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testUnifiedPreferenceUpdate() async {
        let testName = "Update Unified Preference Score"
        let targetMs = 30.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            _ = try await db.queryRaw("""
                UPDATE unified_user_preferences
                SET score = score + 1.0,
                    score_from_discovery = score_from_discovery + 1.0,
                    interaction_count = interaction_count + 1,
                    updated_at = datetime('now')
                WHERE preference_category = 'genre'
                  AND preference_id = 'genre-0'
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: 1,
                passed: passed,
                targetMs: targetMs,
                details: "Updated preference score"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testBatchInsertPerformance() async {
        let testName = "Batch Insert 100 Records"
        let targetMs = 100.0

        let startTime = CFAbsoluteTimeGetCurrent()

        var records: [[String: Any]] = []
        let testUserId = "batch-test-\(UUID().uuidString)"
        let deviceId = "device-\(UUID().uuidString)"
        let now = ISO8601DateFormatter().string(from: Date())

        for i in 0..<100 {
            records.append([
                "id": db.generateUUID(),
                "user_id": testUserId,
                "device_id": deviceId,
                "preference_category": "genre",
                "preference_id": "batch-\(i)",
                "preference_name": "Batch Genre \(i)",
                "score": Double.random(in: 1...10),
                "created_at": now,
                "updated_at": now
            ])
        }

        do {
            try await db.upsert(table: "unified_user_preferences", rows: records)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: 100,
                passed: passed,
                targetMs: targetMs,
                details: "Batch inserted preferences"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    func testComplexJoinQuery() async {
        let testName = "Complex Join: Preferences + Interactions"
        let targetMs = 80.0

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let results: [[String: Any]] = try await db.queryRaw("""
                SELECT
                    up.preference_category,
                    up.preference_name,
                    up.score,
                    COUNT(DISTINCT di.id) as interaction_count,
                    MAX(di.interacted_at) as last_interaction
                FROM unified_user_preferences up
                LEFT JOIN user_discovery_interactions di
                    ON up.user_id = di.user_id
                WHERE up.preference_category = 'genre'
                GROUP BY up.preference_id
                ORDER BY up.score DESC
                LIMIT 10
            """)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let passed = (duration * 1000) <= targetMs

            testResults.append(TestResult(
                name: testName,
                duration: duration,
                recordCount: results.count,
                passed: passed,
                targetMs: targetMs,
                details: "Joined preferences with interactions"
            ))
        } catch {
            testResults.append(TestResult(
                name: testName,
                duration: 0,
                recordCount: 0,
                passed: false,
                targetMs: targetMs,
                details: "FAILED: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Results Output

    func printTestResults() {
        Logger.info("\n=============================================================")
        Logger.info("📊 PERFORMANCE TEST RESULTS")
        Logger.info("=============================================================\n")

        let passedCount = testResults.filter { $0.passed }.count
        let totalCount = testResults.count
        let successRate = Double(passedCount) / Double(totalCount) * 100

        for result in testResults {
            let status = result.passed ? "✅ PASS" : "❌ FAIL"
            let durationMs = result.duration * 1000

            Logger.info("\(status) | \(result.name)")
            Logger.info("   Duration: \(String(format: "%.2f", durationMs))ms / \(String(format: "%.0f", result.targetMs))ms")
            Logger.info("   Records: \(result.recordCount)")
            Logger.info("   Rating: \(result.performanceRating)")
            Logger.info("   Details: \(result.details)\n")
        }

        Logger.info("=============================================================")
        Logger.info("Summary: \(passedCount)/\(totalCount) tests passed (\(String(format: "%.1f", successRate))%)")
        Logger.info("=============================================================\n")

        // Performance statistics
        let avgDuration = testResults.map { $0.duration }.reduce(0, +) / Double(testResults.count)
        let maxDuration = testResults.map { $0.duration }.max() ?? 0
        let minDuration = testResults.map { $0.duration }.min() ?? 0

        Logger.info("📈 Statistics:")
        Logger.info("   Average query time: \(String(format: "%.2f", avgDuration * 1000))ms")
        Logger.info("   Fastest query: \(String(format: "%.2f", minDuration * 1000))ms")
        Logger.info("   Slowest query: \(String(format: "%.2f", maxDuration * 1000))ms")
        Logger.info("")
    }

    // MARK: - Cleanup

    func cleanupTestData() async {
        Logger.info("🧹 Cleaning up test data...")

        do {
            _ = try await db.queryRaw("DELETE FROM unified_user_preferences WHERE user_id LIKE 'test-%' OR user_id LIKE 'batch-test-%'")
            _ = try await db.queryRaw("DELETE FROM user_discovery_interactions WHERE user_id LIKE 'test-%'")
            _ = try await db.queryRaw("DELETE FROM user_search_history WHERE user_id LIKE 'test-%'")
            _ = try await db.queryRaw("DELETE FROM ai_conversation_history WHERE user_id LIKE 'test-%'")

            Logger.info("✅ Test data cleaned up")
        } catch {
            Logger.error("Failed to cleanup test data", error: error)
        }
    }
}
