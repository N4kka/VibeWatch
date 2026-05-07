import Foundation

/// Service for validating YouTube clips
/// Checks: embeddable, public, not age-restricted, correct duration
actor YouTubeValidator {
    private let apiKey: String
    private let baseURL = "https://www.googleapis.com/youtube/v3"
    private let session: URLSession

    // Validation criteria (from Phase 6 plan)
    private let minDuration: Int = 30      // Minimum 30 seconds
    private let maxDuration: Int = 600     // Maximum 10 minutes

    // Rate limiting: YouTube API is more strict
    private var lastRequestTime: Date = .distantPast
    private let minRequestInterval: TimeInterval = 0.1  // 10 requests/second max

    // Quota tracking (videos.list = 1 unit each)
    private(set) var quotaUsed: Int = 0

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Single Video Validation

    /// Validate a single YouTube video
    /// Cost: 1 quota unit
    func validate(videoId: String) async throws -> ClipValidationResult {
        quotaUsed += 1

        let url = "\(baseURL)/videos?part=snippet,contentDetails,status&id=\(videoId)&key=\(apiKey)"

        guard let requestURL = URL(string: url) else {
            return .invalid(videoId: videoId, reason: "Invalid URL")
        }

        // Rate limiting
        await rateLimit()

        do {
            let (data, response) = try await session.data(from: requestURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .invalid(videoId: videoId, reason: "Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                return .invalid(videoId: videoId, reason: "HTTP \(httpResponse.statusCode)")
            }

            let videoResponse = try JSONDecoder().decode(YouTubeVideoListResponse.self, from: data)

            guard let video = videoResponse.items.first else {
                return .invalid(videoId: videoId, reason: "Video not found or deleted")
            }

            return validateVideo(video)

        } catch {
            return .invalid(videoId: videoId, reason: error.localizedDescription)
        }
    }

    /// Validate multiple videos in a single API call (up to 50)
    /// Cost: 1 quota unit (regardless of count!)
    func validateBatch(videoIds: [String]) async throws -> [ClipValidationResult] {
        guard !videoIds.isEmpty else { return [] }

        // YouTube API allows up to 50 video IDs per request
        let batchIds = Array(videoIds.prefix(50))
        quotaUsed += 1

        let idsParam = batchIds.joined(separator: ",")
        let url = "\(baseURL)/videos?part=snippet,contentDetails,status&id=\(idsParam)&key=\(apiKey)"

        guard let requestURL = URL(string: url) else {
            return batchIds.map { .invalid(videoId: $0, reason: "Invalid URL") }
        }

        await rateLimit()

        do {
            let (data, response) = try await session.data(from: requestURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return batchIds.map { .invalid(videoId: $0, reason: "API error") }
            }

            let videoResponse = try JSONDecoder().decode(YouTubeVideoListResponse.self, from: data)

            // Create a map of video ID to video details
            let videoMap = Dictionary(uniqueKeysWithValues: videoResponse.items.map { ($0.id, $0) })

            // Return results for all requested IDs
            return batchIds.map { id in
                if let video = videoMap[id] {
                    return validateVideo(video)
                } else {
                    return .invalid(videoId: id, reason: "Video not found or deleted")
                }
            }

        } catch {
            return batchIds.map { .invalid(videoId: $0, reason: error.localizedDescription) }
        }
    }

    // MARK: - Validation Logic

    private func validateVideo(_ video: YouTubeVideoDetails) -> ClipValidationResult {
        let videoId = video.id

        // Check 1: Must have status info
        guard let status = video.status else {
            return .invalid(videoId: videoId, reason: "No status information")
        }

        // Check 2: Must be embeddable
        guard status.embeddable else {
            return .invalid(videoId: videoId, reason: "Not embeddable")
        }

        // Check 3: Must be public
        guard status.privacyStatus == "public" else {
            return .invalid(videoId: videoId, reason: "Not public (\(status.privacyStatus))")
        }

        // Check 4: Must have content details
        guard let contentDetails = video.contentDetails else {
            return .invalid(videoId: videoId, reason: "No content details")
        }

        // Check 5: Parse and validate duration
        guard let duration = contentDetails.duration.parseISO8601Duration() else {
            return .invalid(videoId: videoId, reason: "Cannot parse duration")
        }

        guard duration >= minDuration else {
            return .invalid(videoId: videoId, reason: "Too short (\(duration)s < \(minDuration)s)")
        }

        guard duration <= maxDuration else {
            return .invalid(videoId: videoId, reason: "Too long (\(duration)s > \(maxDuration)s)")
        }

        // Extract region restrictions
        let availableRegions = contentDetails.regionRestriction?.allowed
        let blockedRegions = contentDetails.regionRestriction?.blocked

        // Extract language
        let language = video.snippet?.defaultLanguage ?? video.snippet?.defaultAudioLanguage

        return .valid(
            videoId: videoId,
            duration: duration,
            availableRegions: availableRegions,
            blockedRegions: blockedRegions,
            language: language
        )
    }

    // MARK: - Rate Limiting

    private func rateLimit() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequestTime)
        if elapsed < minRequestInterval {
            try? await Task.sleep(nanoseconds: UInt64((minRequestInterval - elapsed) * 1_000_000_000))
        }
        lastRequestTime = Date()
    }

    // MARK: - Quota Info

    func getQuotaUsed() -> Int {
        return quotaUsed
    }

    func resetQuotaCounter() {
        quotaUsed = 0
    }
}

// MARK: - Validation Statistics

struct ValidationStats {
    var total: Int = 0
    var valid: Int = 0
    var invalid: Int = 0
    var reasons: [String: Int] = [:]

    mutating func record(_ result: ClipValidationResult) {
        total += 1
        if result.isValid {
            valid += 1
        } else {
            invalid += 1
            if let reason = result.reason {
                reasons[reason, default: 0] += 1
            }
        }
    }

    var validRate: Double {
        guard total > 0 else { return 0 }
        return Double(valid) / Double(total) * 100
    }

    func printSummary() {
        print("\n📊 Validation Statistics:")
        print("  Total: \(total)")
        print("  Valid: \(valid) (\(String(format: "%.1f", validRate))%)")
        print("  Invalid: \(invalid)")

        if !reasons.isEmpty {
            print("\n  Rejection reasons:")
            for (reason, count) in reasons.sorted(by: { $0.value > $1.value }) {
                print("    - \(reason): \(count)")
            }
        }
    }
}
