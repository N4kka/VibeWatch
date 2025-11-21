import Foundation

// MARK: - YouTube API Response Models

struct YouTubeSearchResponse: Codable {
    let items: [YouTubeSearchItem]
}

struct YouTubeSearchItem: Codable {
    let id: VideoId
    let snippet: Snippet
    
    struct VideoId: Codable {
        let videoId: String
    }
    
    struct Snippet: Codable {
        let title: String
        let thumbnails: Thumbnails
        
        struct Thumbnails: Codable {
            let high: Thumbnail
            
            struct Thumbnail: Codable {
                let url: String
            }
        }
    }
}

// MARK: - Legacy Compatibility (for ClipsService)

typealias YouTubeVideo = YouTubeSearchItem
