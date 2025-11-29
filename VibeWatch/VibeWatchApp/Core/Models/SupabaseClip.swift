import Foundation

struct SupabaseClip: Codable {
    let id: String
    let clipId: String
    let videoId: String
    let title: String
    let description: String?
    let videoUrl: String
    let thumbnailUrl: String?
    let movieId: Int?
    let tvShowId: Int?
    let mediaType: String?
    let genres: [String]?
    let actors: [String]?
    let mood: String?
    let keywords: [String]?
    let likes: Int?
    let comments: Int?
    let views: Int?
    let youtubeViews: Int?
    let tmdbRating: Double?
    let qualityScore: Double?
    let isPremium: Bool?
    let createdAt: String?
    let updatedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, genres, actors, mood, keywords
        case likes, comments, views
        case clipId = "clip_id"
        case videoId = "video_id"
        case videoUrl = "video_url"
        case thumbnailUrl = "thumbnail_url"
        case movieId = "movie_id"
        case tvShowId = "tv_show_id"
        case mediaType = "media_type"
        case youtubeViews = "youtube_views"
        case tmdbRating = "tmdb_rating"
        case qualityScore = "quality_score"
        case isPremium = "is_premium"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
