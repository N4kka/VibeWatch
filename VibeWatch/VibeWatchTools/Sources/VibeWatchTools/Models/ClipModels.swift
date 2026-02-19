import Foundation

// MARK: - YouTube API Response Models

struct YouTubeVideoListResponse: Codable {
    let items: [YouTubeVideoDetails]
}

struct YouTubeVideoDetails: Codable {
    let id: String
    let snippet: YouTubeSnippet?
    let contentDetails: YouTubeContentDetails?
    let status: YouTubeStatus?

    struct YouTubeSnippet: Codable {
        let title: String
        let description: String
        let channelTitle: String
        let thumbnails: YouTubeThumbnails
        let defaultLanguage: String?
        let defaultAudioLanguage: String?

        enum CodingKeys: String, CodingKey {
            case title, description, thumbnails
            case channelTitle = "channelTitle"
            case defaultLanguage = "defaultLanguage"
            case defaultAudioLanguage = "defaultAudioLanguage"
        }
    }

    struct YouTubeThumbnails: Codable {
        let high: YouTubeThumbnail?
        let maxres: YouTubeThumbnail?

        var bestURL: String? {
            maxres?.url ?? high?.url
        }
    }

    struct YouTubeThumbnail: Codable {
        let url: String
        let width: Int?
        let height: Int?
    }

    struct YouTubeContentDetails: Codable {
        let duration: String           // ISO 8601 format: "PT4M13S"
        let regionRestriction: RegionRestriction?

        struct RegionRestriction: Codable {
            let allowed: [String]?      // If present, video only available in these regions
            let blocked: [String]?      // If present, video blocked in these regions
        }
    }

    struct YouTubeStatus: Codable {
        let embeddable: Bool
        let privacyStatus: String       // "public", "unlisted", "private"
    }
}

// MARK: - Clip Validation Result

struct ClipValidationResult {
    let videoId: String
    let isValid: Bool
    let reason: String?
    let duration: Int?                  // Duration in seconds
    let isEmbeddable: Bool
    let isPublic: Bool
    let availableRegions: [String]?
    let blockedRegions: [String]?
    let language: String?

    static func valid(
        videoId: String,
        duration: Int,
        availableRegions: [String]? = nil,
        blockedRegions: [String]? = nil,
        language: String? = nil
    ) -> ClipValidationResult {
        ClipValidationResult(
            videoId: videoId,
            isValid: true,
            reason: nil,
            duration: duration,
            isEmbeddable: true,
            isPublic: true,
            availableRegions: availableRegions,
            blockedRegions: blockedRegions,
            language: language
        )
    }

    static func invalid(videoId: String, reason: String) -> ClipValidationResult {
        ClipValidationResult(
            videoId: videoId,
            isValid: false,
            reason: reason,
            duration: nil,
            isEmbeddable: false,
            isPublic: false,
            availableRegions: nil,
            blockedRegions: nil,
            language: nil
        )
    }
}

// MARK: - Clip for Database Storage

struct ClipRecord: Codable {
    let id: String                      // UUID
    let clipId: String                  // Unique identifier
    let videoId: String                 // YouTube video ID
    let title: String
    let description: String
    let videoUrl: String
    let thumbnailUrl: String
    let movieId: Int?
    let tvShowId: Int?
    let mediaType: String               // "movie" or "tv"
    let genres: [String]
    let actors: [String]
    let mood: String?
    let keywords: [String]
    let likes: Int
    let comments: Int
    let views: Int
    let durationSeconds: Int
    let isActive: Bool
    let isPremium: Bool
    let availableRegions: [String]?
    let blockedRegions: [String]?
    let primaryLanguage: String?
    let primaryRegion: String?
    let validatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case clipId = "clip_id"
        case videoId = "video_id"
        case title, description
        case videoUrl = "video_url"
        case thumbnailUrl = "thumbnail_url"
        case movieId = "movie_id"
        case tvShowId = "tv_show_id"
        case mediaType = "media_type"
        case genres, actors, mood, keywords
        case likes, comments, views
        case durationSeconds = "duration_seconds"
        case isActive = "is_active"
        case isPremium = "is_premium"
        case availableRegions = "available_regions"
        case blockedRegions = "blocked_regions"
        case primaryLanguage = "primary_language"
        case primaryRegion = "primary_region"
        case validatedAt = "validated_at"
    }
}

// MARK: - Duration Parsing

extension String {
    /// Parse ISO 8601 duration (e.g., "PT4M13S") to seconds
    func parseISO8601Duration() -> Int? {
        let pattern = #"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else {
            return nil
        }

        var seconds = 0

        if let hourRange = Range(match.range(at: 1), in: self) {
            seconds += (Int(self[hourRange]) ?? 0) * 3600
        }
        if let minuteRange = Range(match.range(at: 2), in: self) {
            seconds += (Int(self[minuteRange]) ?? 0) * 60
        }
        if let secondRange = Range(match.range(at: 3), in: self) {
            seconds += Int(self[secondRange]) ?? 0
        }

        return seconds
    }
}
