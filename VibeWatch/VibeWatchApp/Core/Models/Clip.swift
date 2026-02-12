import Foundation

struct Clip: Codable, Identifiable {
    let id: String
    let movieId: Int?
    let tvShowId: Int?
    let title: String
    let description: String
    let videoURL: String
    let videoId: String
    let thumbnailURL: String?
    let duration: Int
    var likes: Int
    var comments: Int
    let createdAt: Date
    var isLiked: Bool = false
    
    // Segment information for 15-second cuts
    let isSegment: Bool
    let originalClipId: String?
    let segmentIndex: Int?
    let startTime: Int? // Start time in seconds for this segment

    // Country/Language metadata for personalization
    let countryCode: String?
    let languageCode: String?
    let sourceRegion: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, duration, likes, comments, isLiked
        case movieId = "movie_id"
        case tvShowId = "tv_show_id"
        case videoURL = "video_url"
        case videoId = "video_id"
        case thumbnailURL = "thumbnail_url"
        case createdAt = "created_at"
        case isSegment = "is_segment"
        case originalClipId = "original_clip_id"
        case segmentIndex = "segment_index"
        case startTime = "start_time"
        case countryCode = "country_code"
        case languageCode = "language_code"
        case sourceRegion = "source_region"
    }
    
    init(id: String, movieId: Int?, tvShowId: Int?, title: String, description: String,
         videoURL: String, videoId: String, thumbnailURL: String?, duration: Int,
         likes: Int, comments: Int, createdAt: Date, isLiked: Bool = false,
         isSegment: Bool = false, originalClipId: String? = nil,
         segmentIndex: Int? = nil, startTime: Int? = nil,
         countryCode: String? = nil, languageCode: String? = nil, sourceRegion: String? = nil) {
        self.id = id
        self.movieId = movieId
        self.tvShowId = tvShowId
        self.title = title
        self.description = description
        self.videoURL = videoURL
        self.videoId = videoId
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.likes = likes
        self.comments = comments
        self.createdAt = createdAt
        self.isLiked = isLiked
        self.isSegment = isSegment
        self.originalClipId = originalClipId
        self.segmentIndex = segmentIndex
        self.startTime = startTime
        self.countryCode = countryCode
        self.languageCode = languageCode
        self.sourceRegion = sourceRegion
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        movieId = try container.decodeIfPresent(Int.self, forKey: .movieId)
        tvShowId = try container.decodeIfPresent(Int.self, forKey: .tvShowId)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        videoURL = try container.decode(String.self, forKey: .videoURL)
        videoId = try container.decode(String.self, forKey: .videoId)
        thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailURL)
        duration = try container.decode(Int.self, forKey: .duration)
        likes = try container.decode(Int.self, forKey: .likes)
        comments = try container.decode(Int.self, forKey: .comments)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        isSegment = try container.decodeIfPresent(Bool.self, forKey: .isSegment) ?? false
        originalClipId = try container.decodeIfPresent(String.self, forKey: .originalClipId)
        segmentIndex = try container.decodeIfPresent(Int.self, forKey: .segmentIndex)
        startTime = try container.decodeIfPresent(Int.self, forKey: .startTime)
        // Backward compatible: decode new metadata fields if present
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        sourceRegion = try container.decodeIfPresent(String.self, forKey: .sourceRegion)
    }
}

// Update the Clip model to include mediaType helper
extension Clip {
    var inferredMediaType: MediaType {
        if movieId != nil {
            return .movie
        } else if tvShowId != nil {
            return .tv
        }
        return .movie // default
    }
}
