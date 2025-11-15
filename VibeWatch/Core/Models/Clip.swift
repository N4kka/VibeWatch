import Foundation

struct Clip: Codable, Identifiable {
    let id: String
    let movieId: Int?
    let tvShowId: Int?
    let title: String
    let description: String
    let videoURL: String
    let thumbnailURL: String?
    let duration: Int
    var likes: Int
    var comments: Int
    let createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, duration, likes, comments
        case movieId = "movie_id"
        case tvShowId = "tv_show_id"
        case videoURL = "video_url"
        case thumbnailURL = "thumbnail_url"
        case createdAt = "created_at"
    }
}
