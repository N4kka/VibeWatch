import Foundation

@MainActor
final class CerebrasBackendJobManager {
    static let shared = CerebrasBackendJobManager()

    enum JobType: String {
        case generateCarouselDescriptions = "generate_carousel_descriptions"
        case enhanceClipMetadata = "enhance_clip_metadata"
        case generateEmbeddings = "generate_embeddings"
        case analyzeUserBehavior = "analyze_user_behavior"
    }

    private struct JobRecord: Decodable {
        let id: String
        let jobType: String
        let payloadJSON: String?
        let status: String
        let attempts: Int
        let maxAttempts: Int
        let priority: Int
        let scheduledAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case jobType = "job_type"
            case payloadJSON = "payload_json"
            case status
            case attempts
            case maxAttempts = "max_attempts"
            case priority
            case scheduledAt = "scheduled_at"
        }
    }

    private struct PersonalizedDiscoveryRow: Decodable {
        let mediaId: Int
        let description: String?

        enum CodingKeys: String, CodingKey {
            case mediaId = "media_id"
            case description
        }
    }

    private struct ClipMetadataCandidateRow: Decodable {
        let clipId: String
        let videoId: String
        let title: String
        let description: String?
        let videoURL: String
        let thumbnailURL: String?
        let movieId: Int?
        let tvShowId: Int?
        let createdAt: String?
        let aiDescription: String?
        let moodTags: String?

        enum CodingKeys: String, CodingKey {
            case clipId = "clip_id"
            case videoId = "video_id"
            case title
            case description
            case videoURL = "video_url"
            case thumbnailURL = "thumbnail_url"
            case movieId = "movie_id"
            case tvShowId = "tv_show_id"
            case createdAt = "created_at"
            case aiDescription = "ai_description"
            case moodTags = "mood_tags"
        }
    }

    private struct CachedDetailRow: Decodable {
        let title: String
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let voteAverage: Double?
        let runtime: Int?
        let genres: String?

        enum CodingKeys: String, CodingKey {
            case title
            case overview
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case releaseDate = "release_date"
            case voteAverage = "vote_average"
            case runtime
            case genres
        }
    }

    private let sqliteService: SQLiteService
    private let cerebrasService: CerebrasService
    private let tmdbService: TMDBServiceProtocol

    private let embeddingModel = "zai-glm-4.7"
    private let embeddingDimensions = 64

    private init(
        sqliteService: SQLiteService = .shared,
        cerebrasService: CerebrasService = .shared,
        tmdbService: TMDBServiceProtocol = TMDBService.shared
    ) {
        self.sqliteService = sqliteService
        self.cerebrasService = cerebrasService
        self.tmdbService = tmdbService
    }

    func enqueueDailyJobsIfNeeded() async {
        guard AuthService.shared.currentUser?.id != nil else { return }

        let now = Date()
        let dayKey = DateFormatter.cerebrasDayFormatter.string(from: now)
        let existingKey = (try? await fetchMetadataValue(for: "cerebras_daily_jobs_enqueued_day")) ?? nil
        guard existingKey != dayKey else { return }

        let nowISO = ISO8601DateFormatter().string(from: now)
        let jobsToEnqueue: [(JobType, Int)] = [
            (.generateCarouselDescriptions, 30),
            (.enhanceClipMetadata, 20),
            (.generateEmbeddings, 10),
            (.analyzeUserBehavior, 5)
        ]

        for (type, priority) in jobsToEnqueue {
            await enqueueJob(type: type, priority: priority, scheduledAtISO: nowISO)
        }

        try? await setMetadataValue(key: "cerebras_daily_jobs_enqueued_day", value: dayKey)
        Logger.debug("[CerebrasBackendJobManager] Enqueued daily jobs for \(dayKey)")
    }

    func processPendingJobs(maxJobs: Int = 4, timeBudgetSeconds: TimeInterval = 25) async {
        // Guard: skip silently if no active user session — Edge Function requires auth
        guard let session = try? await AuthService.shared.client?.auth.session,
              !session.accessToken.isEmpty else {
            Logger.info("[CerebrasBackend] No active session — skipping background AI jobs")
            return
        }

        let start = Date()
        var processed = 0
        var successCount = 0
        var failureCount = 0

        Logger.info("[CerebrasBackendJobManager] Starting job processing (max: \(maxJobs), budget: \(timeBudgetSeconds)s)")

        while processed < maxJobs, Date().timeIntervalSince(start) < timeBudgetSeconds {
            guard let job = try? await fetchNextPendingJob() else {
                Logger.debug("[CerebrasBackendJobManager] No more pending jobs")
                break
            }

            let jobStart = Date()
            do {
                try await markJobRunning(jobId: job.id, newAttempts: job.attempts + 1)
                try await run(job: job)
                try await markJobCompleted(jobId: job.id)

                let duration = Date().timeIntervalSince(jobStart)
                successCount += 1
                await recordJobMetrics(jobType: job.jobType, success: true, duration: duration, attempts: job.attempts + 1)
                Logger.info("[CerebrasBackendJobManager] ✅ Job completed: \(job.jobType) in \(String(format: "%.2f", duration))s")
            } catch {
                try? await markJobFailedOrRescheduled(job: job, error: error)

                let duration = Date().timeIntervalSince(jobStart)
                failureCount += 1
                await recordJobMetrics(jobType: job.jobType, success: false, duration: duration, attempts: job.attempts + 1)
                Logger.error("[CerebrasBackendJobManager] ❌ Job failed: \(job.jobType) - \(error.localizedDescription)")
            }
            processed += 1
        }

        let totalDuration = Date().timeIntervalSince(start)
        Logger.info("[CerebrasBackendJobManager] Batch complete: \(successCount) succeeded, \(failureCount) failed in \(String(format: "%.2f", totalDuration))s")

        // Log daily success rate
        await logDailySuccessRate()
    }

    // MARK: - Job Execution

    private func run(job: JobRecord) async throws {
        guard let type = JobType(rawValue: job.jobType) else { return }

        switch type {
        case .generateCarouselDescriptions:
            try await generateCarouselDescriptions()
        case .enhanceClipMetadata:
            try await enhanceClipMetadata()
        case .generateEmbeddings:
            try await generateEmbeddings()
        case .analyzeUserBehavior:
            try await analyzeUserBehavior()
        }
    }

    private func generateCarouselDescriptions() async throws {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let profile = await UserPreferenceManager.shared.aggregatePreferences()

        let nowISO = ISO8601DateFormatter().string(from: Date())
        let rows: [PersonalizedDiscoveryRow] = (try? await sqliteService.query("""
            SELECT media_id, description
            FROM personalized_discovery
            WHERE user_id = ?
              AND expires_at > ?
              AND (description IS NULL OR description = '')
            ORDER BY generated_at DESC
            LIMIT 120
        """, parameters: [userId, nowISO])) ?? []

        let mediaIds = Array(Set(rows.map(\.mediaId))).prefix(60)
        guard !mediaIds.isEmpty else { return }

        var movies: [Movie] = []
        movies.reserveCapacity(mediaIds.count)

        for mediaId in mediaIds {
            if let cached = try? await fetchCachedMovieDetails(mediaId: mediaId) {
                movies.append(cached)
            } else if let fetched = try? await tmdbService.getMovieDetails(id: mediaId) {
                movies.append(fetched)
            }
        }

        guard !movies.isEmpty else { return }

        let descriptions = try await cerebrasService.enhanceMovieDescriptions(
            movies: movies,
            userTone: "casual",
            userPreferences: profile.userId.isEmpty ? nil : profile
        )

        for movie in movies {
            if let description = descriptions[String(movie.id)], !description.isEmpty {
                try? await sqliteService.update(
                    "personalized_discovery",
                    values: ["description": description],
                    where: "user_id = ? AND media_id = ?",
                    parameters: [userId, movie.id]
                )
            }
        }

        Logger.debug("[CerebrasBackendJobManager] Updated carousel descriptions: \(descriptions.count)")
    }

    private func enhanceClipMetadata() async throws {
        let rows: [ClipMetadataCandidateRow] = (try? await sqliteService.query("""
            SELECT clip_id, video_id, title, description, video_url, thumbnail_url,
                   movie_id, tv_show_id, created_at, ai_description, mood_tags
            FROM clips
            WHERE is_active = 1
              AND (ai_description IS NULL OR ai_description = '' OR mood_tags IS NULL OR mood_tags = '')
              AND deleted_at IS NULL
            ORDER BY fetched_at DESC
            LIMIT 30
        """)) ?? []

        guard !rows.isEmpty else { return }

        for row in rows {
            guard let movieId = row.movieId else { continue }
            guard let movie = try? await tmdbService.getMovieDetails(id: movieId) else { continue }

            let createdAtDate = DateFormatter.sqliteDateTime.date(from: row.createdAt ?? "") ?? Date()
            let clip = Clip(
                id: row.clipId,
                movieId: row.movieId,
                tvShowId: row.tvShowId,
                title: row.title,
                description: row.description ?? "",
                videoURL: row.videoURL,
                videoId: row.videoId,
                thumbnailURL: row.thumbnailURL,
                duration: 0,
                likes: 0,
                comments: 0,
                createdAt: createdAtDate
            )

            let metadata = try await cerebrasService.generateClipMetadata(clip: clip, movieContext: movie)

            let moodTags = (try? String(data: JSONEncoder().encode(metadata.moods), encoding: .utf8)) ?? "[]"

            try? await sqliteService.update(
                "clips",
                values: [
                    "ai_description": metadata.description,
                    "mood_tags": moodTags,
                    "updated_at": DateFormatter.sqliteDateTime.string(from: Date())
                ],
                where: "clip_id = ?",
                parameters: [row.clipId]
            )
        }

        Logger.debug("[CerebrasBackendJobManager] Enhanced clip metadata: \(rows.count)")
    }

    private func generateEmbeddings() async throws {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let profile = await UserPreferenceManager.shared.aggregatePreferences()

        let liked = Array(profile.recentActivity.likedMedia.prefix(2))
        guard !liked.isEmpty else { return }

        for likedMedia in liked where likedMedia.mediaType == .movie {
            guard let seedMovie = try? await tmdbService.getMovieDetails(id: likedMedia.id) else { continue }

            if (try? await fetchEmbedding(mediaType: "movie", mediaId: seedMovie.id)) == nil {
                if let vector = try? await cerebrasService.generateMovieEmbedding(
                    movie: seedMovie,
                    dimensions: embeddingDimensions
                ) {
                    try? await upsertEmbedding(mediaType: "movie", mediaId: seedMovie.id, vector: vector)
                }
            }

            let similar = (try? await tmdbService.getSimilarMovies(id: seedMovie.id, page: 1).results) ?? []
            for movie in similar.prefix(10) {
                if (try? await fetchEmbedding(mediaType: "movie", mediaId: movie.id)) != nil { continue }
                if let vector = try? await cerebrasService.generateMovieEmbedding(
                    movie: movie,
                    dimensions: embeddingDimensions
                ) {
                    try? await upsertEmbedding(mediaType: "movie", mediaId: movie.id, vector: vector)
                }
            }
        }

        Logger.debug("[CerebrasBackendJobManager] Generated embeddings for liked+similar")
    }

    private func analyzeUserBehavior() async throws {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let deviceId = await sqliteService.getOrCreateDeviceId()

        let interactions: [UserInteraction] = await buildRecentInteractions(userId: userId)
        guard !interactions.isEmpty else { return }

        let insights = try await cerebrasService.analyzeUserBehaviorPatterns(interactions: interactions)
        let insightsJSON = (try? String(data: JSONEncoder().encode(insights), encoding: .utf8)) ?? "{}"

        _ = try? await sqliteService.insert("user_behavior_insights", values: [
            "id": sqliteService.generateUUID(),
            "user_id": userId,
            "device_id": deviceId,
            "insights_json": insightsJSON,
            "generated_at": ISO8601DateFormatter().string(from: Date())
        ])

        Logger.debug("[CerebrasBackendJobManager] Stored behavior insights")
    }

    private func buildRecentInteractions(userId: String) async -> [UserInteraction] {
        let discoveryRows = (try? await sqliteService.queryRaw("""
            SELECT interaction_type, media_id, media_type, session_duration
            FROM user_discovery_interactions
            WHERE user_id = ?
            ORDER BY interacted_at DESC
            LIMIT 25
        """, parameters: [userId])) ?? []

        var interactions: [UserInteraction] = []
        interactions.reserveCapacity(50)

        for row in discoveryRows {
            let interactionType = (row["interaction_type"] as? String) ?? ""
            let mediaId = row["media_id"] as? Int
            let mediaTypeRaw = (row["media_type"] as? String) ?? "movie"
            let duration = row["session_duration"] as? Int

            let engagement: Double
            switch interactionType {
            case "tap": engagement = 1.0
            case "watch_trailer": engagement = 2.0
            case "add_to_watchlist": engagement = 3.0
            default: engagement = 1.0
            }

            let boosted = engagement + min(Double(duration ?? 0) / 60.0, 2.0)
            interactions.append(UserInteraction(
                source: .discovery,
                mediaId: mediaId,
                mediaType: mediaTypeRaw == "tv" ? .tv : .movie,
                engagementScore: boosted,
                metadata: [:]
            ))
        }

        let searchRows = (try? await sqliteService.queryRaw("""
            SELECT query, result_count, searched_at
            FROM user_search_history
            WHERE user_id = ?
            ORDER BY searched_at DESC
            LIMIT 10
        """, parameters: [userId])) ?? []

        for row in searchRows {
            let query = (row["query"] as? String) ?? ""
            let count = row["result_count"] as? Int ?? 0
            interactions.append(UserInteraction(
                source: .search,
                engagementScore: 0.5 + min(Double(count) / 20.0, 1.0),
                metadata: ["query": query]
            ))
        }

        return interactions
    }

    // MARK: - Job Queue Storage

    private func enqueueJob(type: JobType, priority: Int, scheduledAtISO: String) async {
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let todayFloorISO = "\(String(nowISO.prefix(10)))T00:00:00Z"

        let alreadyQueued = (try? await sqliteService.exists(
            "cerebras_job_queue",
            where: "job_type = ? AND status IN ('pending','running') AND created_at >= ?",
            parameters: [type.rawValue, todayFloorISO]
        )) ?? false
        if alreadyQueued { return }

        _ = try? await sqliteService.insert("cerebras_job_queue", values: [
            "id": sqliteService.generateUUID(),
            "job_type": type.rawValue,
            "payload_json": NSNull(),
            "status": "pending",
            "attempts": 0,
            "max_attempts": 3,
            "priority": priority,
            "scheduled_at": scheduledAtISO,
            "created_at": nowISO
        ])
    }

    private func fetchNextPendingJob() async throws -> JobRecord? {
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let jobs: [JobRecord] = try await sqliteService.query("""
            SELECT *
            FROM cerebras_job_queue
            WHERE status = 'pending'
              AND (scheduled_at IS NULL OR scheduled_at <= ?)
            ORDER BY priority DESC, created_at ASC
            LIMIT 1
        """, parameters: [nowISO])
        return jobs.first
    }

    private func markJobRunning(jobId: String, newAttempts: Int) async throws {
        try await sqliteService.update(
            "cerebras_job_queue",
            values: [
                "status": "running",
                "attempts": newAttempts,
                "started_at": ISO8601DateFormatter().string(from: Date()),
                "last_error": NSNull()
            ],
            where: "id = ?",
            parameters: [jobId]
        )
    }

    private func markJobCompleted(jobId: String) async throws {
        try await sqliteService.update(
            "cerebras_job_queue",
            values: [
                "status": "completed",
                "completed_at": ISO8601DateFormatter().string(from: Date())
            ],
            where: "id = ?",
            parameters: [jobId]
        )
    }

    private func markJobFailedOrRescheduled(job: JobRecord, error: Error) async throws {
        let nextAttempts = job.attempts + 1
        let now = Date()
        let nowISO = ISO8601DateFormatter().string(from: now)
        let backoffSeconds = min(pow(2.0, Double(nextAttempts)) * 30.0, 6 * 3600.0)
        let nextISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(backoffSeconds))

        if nextAttempts >= job.maxAttempts {
            try await sqliteService.update(
                "cerebras_job_queue",
                values: [
                    "status": "failed",
                    "completed_at": nowISO,
                    "last_error": error.localizedDescription
                ],
                where: "id = ?",
                parameters: [job.id]
            )
        } else {
            try await sqliteService.update(
                "cerebras_job_queue",
                values: [
                    "status": "pending",
                    "scheduled_at": nextISO,
                    "last_error": error.localizedDescription
                ],
                where: "id = ?",
                parameters: [job.id]
            )
        }
    }

    // MARK: - Cache Helpers

    private func fetchCachedMovieDetails(mediaId: Int) async throws -> Movie? {
        let cached: [CachedDetailRow] = try await sqliteService.query("""
            SELECT title, overview, poster_path, backdrop_path, release_date, vote_average, runtime, genres
            FROM detail_cache
            WHERE media_id = ? AND media_type = 'movie' AND deleted_at IS NULL
            ORDER BY updated_at DESC
            LIMIT 1
        """, parameters: [mediaId])

        if let row = cached.first {
            let genreIds = row.genres.flatMap { try? JSONDecoder().decode([Int].self, from: Data($0.utf8)) }
            return Movie(
                id: mediaId,
                title: row.title,
                overview: row.overview ?? "",
                posterPath: row.posterPath,
                backdropPath: row.backdropPath,
                releaseDate: row.releaseDate,
                voteAverage: row.voteAverage ?? 0.0,
                voteCount: 0,
                genreIds: genreIds,
                genres: nil,
                adult: false,
                originalLanguage: "",
                popularity: 0.0,
                runtime: row.runtime,
                status: nil,
                tagline: nil,
                productionCountries: nil,
                imdbId: nil
            )
        }

        return nil
    }

    // MARK: - Embeddings

    private func fetchEmbedding(mediaType: String, mediaId: Int) async throws -> [Double]? {
        let rows = try await sqliteService.queryRaw("""
            SELECT vector_json
            FROM media_embeddings
            WHERE media_type = ? AND media_id = ? AND model = ?
            LIMIT 1
        """, parameters: [mediaType, mediaId, embeddingModel])

        guard let json = rows.first?["vector_json"] as? String else { return nil }
        return try JSONDecoder().decode([Double].self, from: Data(json.utf8))
    }

    private func upsertEmbedding(mediaType: String, mediaId: Int, vector: [Double]) async throws {
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let json = (try? String(data: JSONEncoder().encode(vector), encoding: .utf8)) ?? "[]"

        try await sqliteService.upsert(table: "media_embeddings", rows: [[
            "media_type": mediaType,
            "media_id": mediaId,
            "model": embeddingModel,
            "dimensions": vector.count,
            "vector_json": json,
            "created_at": nowISO,
            "updated_at": nowISO
        ]])
    }

    // MARK: - app_metadata Helpers

    private func fetchMetadataValue(for key: String) async throws -> String? {
        let rows = try await sqliteService.queryRaw("""
            SELECT value_text
            FROM app_metadata
            WHERE key_name = ?
            LIMIT 1
        """, parameters: [key])
        return rows.first?["value_text"] as? String
    }

    private func setMetadataValue(key: String, value: String) async throws {
        try await sqliteService.executeWrite("""
            INSERT OR REPLACE INTO app_metadata (key_name, value_text)
            VALUES (?, ?)
        """, parameters: [key, value])
    }

    // MARK: - Metrics & Monitoring

    /// Record job execution metrics for monitoring and optimization
    private func recordJobMetrics(jobType: String, success: Bool, duration: TimeInterval, attempts: Int) async {
        let nowISO = ISO8601DateFormatter().string(from: Date())

        _ = try? await sqliteService.insert("cerebras_job_metrics", values: [
            "id": sqliteService.generateUUID(),
            "job_type": jobType,
            "success": success ? 1 : 0,
            "duration_seconds": duration,
            "attempts": attempts,
            "executed_at": nowISO
        ])
    }

    /// Log daily success rate summary
    private func logDailySuccessRate() async {
        let today = DateFormatter.cerebrasDayFormatter.string(from: Date())
        let todayStart = "\(today)T00:00:00Z"

        let metrics = try? await sqliteService.queryRaw("""
            SELECT
                job_type,
                COUNT(*) as total,
                SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as successes,
                AVG(duration_seconds) as avg_duration,
                AVG(attempts) as avg_attempts
            FROM cerebras_job_metrics
            WHERE executed_at >= ?
            GROUP BY job_type
        """, parameters: [todayStart])

        guard let metrics = metrics, !metrics.isEmpty else { return }

        Logger.info("[CerebrasBackendJobManager] 📊 Daily Metrics for \(today):")
        for row in metrics {
            let jobType = row["job_type"] as? String ?? "unknown"
            let total = row["total"] as? Int ?? 0
            let successes = row["successes"] as? Int ?? 0
            let avgDuration = row["avg_duration"] as? Double ?? 0.0
            let avgAttempts = row["avg_attempts"] as? Double ?? 1.0
            let successRate = total > 0 ? Double(successes) / Double(total) * 100.0 : 0.0

            Logger.info("  - \(jobType): \(successes)/\(total) (\(String(format: "%.1f%%", successRate))), avg: \(String(format: "%.2f", avgDuration))s, attempts: \(String(format: "%.1f", avgAttempts))")
        }
    }

    /// Get overall job health metrics (for debugging/monitoring)
    func getJobHealthMetrics() async -> JobHealthMetrics {
        let last24Hours = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))

        let metrics = try? await sqliteService.queryRaw("""
            SELECT
                COUNT(*) as total_jobs,
                SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as successful_jobs,
                AVG(duration_seconds) as avg_duration,
                MAX(duration_seconds) as max_duration
            FROM cerebras_job_metrics
            WHERE executed_at >= ?
        """, parameters: [last24Hours])

        guard let row = metrics?.first else {
            return JobHealthMetrics(totalJobs: 0, successRate: 0, avgDuration: 0, maxDuration: 0)
        }

        let total = row["total_jobs"] as? Int ?? 0
        let successful = row["successful_jobs"] as? Int ?? 0
        let successRate = total > 0 ? Double(successful) / Double(total) : 0.0

        return JobHealthMetrics(
            totalJobs: total,
            successRate: successRate,
            avgDuration: row["avg_duration"] as? Double ?? 0,
            maxDuration: row["max_duration"] as? Double ?? 0
        )
    }
}

// MARK: - Job Health Metrics

struct JobHealthMetrics {
    let totalJobs: Int
    let successRate: Double
    let avgDuration: Double
    let maxDuration: Double

    var isHealthy: Bool {
        // Consider healthy if success rate > 80% and avg duration < 20s
        successRate > 0.8 && avgDuration < 20.0
    }
}

private extension DateFormatter {
    static let cerebrasDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let sqliteDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
