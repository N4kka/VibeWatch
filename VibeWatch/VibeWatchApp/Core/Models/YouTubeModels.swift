import Foundation

// MARK: - YouTube API Search Response Models

public struct YouTubeSearchResponse: Codable {
    public let items: [YouTubeSearchItem]
}

public struct YouTubeSearchItem: Codable {
    public let id: VideoId
    public let snippet: Snippet
    
    public struct VideoId: Codable {
        public let videoId: String
    }
    
    public struct Snippet: Codable {
        public let title: String
        public let thumbnails: Thumbnails
        
        public struct Thumbnails: Codable {
            public let high: Thumbnail
            
            public struct Thumbnail: Codable {
                public let url: String
            }
        }
    }
}

// MARK: - YouTube API Video Details Models (for validation)

public struct YouTubeVideoResponse: Codable {
    public let items: [YouTubeVideoItem]
}

public struct YouTubeVideoItem: Codable {
    public let status: VideoStatus
    public let contentDetails: ContentDetails
}

public struct VideoStatus: Codable {
    public let uploadStatus: String
    public let privacyStatus: String
    public let embeddable: Bool
}

public struct ContentDetails: Codable {
    public let contentRating: ContentRating
}

public struct ContentRating: Codable {
    public let ytRating: String?
}


// MARK: - Legacy Compatibility (for ClipsService)

typealias YouTubeVideo = YouTubeSearchItem
