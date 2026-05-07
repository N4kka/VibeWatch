import Foundation

@MainActor
final class ClipsService {
    static let shared = ClipsService()
    
    private let tmdbService = TMDBService.shared
    private let youtubeAPIKey = Config.youtubeApiKey  // Phase 5: Use Config instead of hardcoded key
    private let session: URLSession

    // In-memory storage for likes (since you don't have a backend)
    private var likedClips: Set<String> = []
    private var clipLikeCounts: [String: Int] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)

        // Load saved likes from UserDefaults
        loadLikedClips()
    }
    
    // MARK: - Main Clips Fetching (Smart Algorithm)
    
    func fetchTrendingClips(page: Int = 1, limit: Int = 20) async throws -> [Clip] {
        // Use the smart algorithm engine
        let algorithmEngine = PersonalizedClipsService.shared
        let enhancedClips = try await algorithmEngine.generateSmartFeed(count: limit)
        
        // Convert EnhancedClip back to Clip
        var clips = enhancedClips.map { $0.clip }
        
        // Apply saved like counts and liked status to clips
        clips = clips.map { clip in
            var updatedClip = clip
            if let savedLikeCount = clipLikeCounts[clip.id] {
                updatedClip.likes = savedLikeCount
            }
            updatedClip.isLiked = likedClips.contains(clip.id)
            return updatedClip
        }
        
        Logger.info("[ClipsService] Smart feed generated: \(clips.count) clips with personalization & diversity")
        return clips
    }
    
    /// Search clips by free-text query (YouTube-first). Returns lightweight Clip models so they can be played immediately.
    func searchClips(query: String, limit: Int = 20) async throws -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        let maxResults = max(5, min(limit, 30))
        let searchResults = try await searchYouTubeClips(query: trimmed, maxResults: maxResults)
        
        return searchResults.map { item in
            let videoId = item.id.videoId
            return Clip(
                id: "yt-\(videoId)",
                movieId: nil,
                tvShowId: nil,
                title: item.snippet.title,
                description: item.snippet.title,
                videoURL: "https://www.youtube.com/watch?v=\(videoId)",
                videoId: videoId,
                thumbnailURL: item.snippet.thumbnails.high.url,
                duration: 0,
                likes: 0,
                comments: 0,
                createdAt: Date()
            )
        }
    }
    
    // MARK: - TMDb Videos
    
    private func fetchTMDBVideos(for media: MediaItem) async throws -> [Video] {
        let response: TMDBVideosResponse
        
        if media.isMovie {
            response = try await tmdbService.getMovieVideos(id: media.id)
        } else {
            response = try await tmdbService.getTVShowVideos(id: media.id)
        }
        
        // Return ALL video types - no filtering! (trailers, clips, teasers, behind-the-scenes, etc.)
        return response.results.filter { $0.site == "YouTube" }
    }
    
    // MARK: - YouTube API
    
    private func searchYouTubeClips(query: String, maxResults: Int = 5) async throws -> [YouTubeSearchItem] {
        guard var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "q", value: "\(query) official"), // Removed exclusions - show ALL content
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoDuration", value: "short"),
            URLQueryItem(name: "maxResults", value: "\(max(1, min(maxResults, 50)))"),
            URLQueryItem(name: "key", value: youtubeAPIKey)
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(YouTubeSearchResponse.self, from: data)
        
        // Return ALL content - no filtering!
        return response.items
    }
    
    // MARK: - Combine Results
    
    func clips(for media: MediaItem, maxResults: Int = 5) async throws -> [Clip] {
        var clips: [Clip] = []
        
        // First try TMDb videos
        if let tmdbVideos = try? await fetchTMDBVideos(for: media) {
            clips.append(contentsOf: tmdbVideos.prefix(maxResults).map { video in
                Clip(
                    id: "\(media.id)-\(video.key)",
                    movieId: media.isMovie ? media.id : nil,
                    tvShowId: media.isMovie ? nil : media.id,
                    title: media.title,
                    description: video.name,
                    videoURL: "https://www.youtube.com/watch?v=\(video.key)",
                    videoId: video.key,
                    thumbnailURL: "https://img.youtube.com/vi/\(video.key)/maxresdefault.jpg",
                    duration: 0,
                    likes: 0,
                    comments: 0,
                    createdAt: Date()
                )
            })
        }
        
        // If no TMDb clips, try YouTube search
        if clips.isEmpty {
            if let youtubeVideos = try? await searchYouTubeClips(query: media.title, maxResults: maxResults) {
                clips.append(contentsOf: youtubeVideos.map { video in
                    Clip(
                        id: "\(media.id)-\(video.id.videoId)",
                        movieId: media.isMovie ? media.id : nil,
                        tvShowId: media.isMovie ? nil : media.id,
                        title: media.title,
                        description: video.snippet.title,
                        videoURL: "https://www.youtube.com/watch?v=\(video.id.videoId)",
                        videoId: video.id.videoId,
                        thumbnailURL: video.snippet.thumbnails.high.url,
                        duration: 0,
                        likes: 0,
                        comments: 0,
                        createdAt: Date()
                    )
                })
            }
        }
        
        return Array(clips.prefix(maxResults))
    }
    
    // MARK: - Like Functionality
    
    func updateLikeStatus(clipId: String, isLiked: Bool) async throws {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Update in-memory storage
        if isLiked {
            likedClips.insert(clipId)
        } else {
            likedClips.remove(clipId)
        }
        
        // Save to UserDefaults
        saveLikedClips()
    }
    
    func isClipLiked(_ clipId: String) -> Bool {
        return likedClips.contains(clipId)
    }
    
    func getLikedClipIds() -> Set<String> {
        return likedClips
    }
    
    func updateLikeCount(clipId: String, newCount: Int) {
        clipLikeCounts[clipId] = newCount
        saveClipLikeCounts()
    }
    
    // MARK: - Persistence
    
    private func loadLikedClips() {
        if let savedLikes = UserDefaults.standard.array(forKey: "likedClips") as? [String] {
            likedClips = Set(savedLikes)
        }
        
        if let savedCounts = UserDefaults.standard.dictionary(forKey: "clipLikeCounts") as? [String: Int] {
            clipLikeCounts = savedCounts
        }
    }
    
    private func saveLikedClips() {
        UserDefaults.standard.set(Array(likedClips), forKey: "likedClips")
    }
    
    private func saveClipLikeCounts() {
        UserDefaults.standard.set(clipLikeCounts, forKey: "clipLikeCounts")
    }
}

// MARK: - Supporting Models

struct MediaItem {
    let id: Int
    let title: String
    let isMovie: Bool
    
    init(movie: Movie) {
        self.id = movie.id
        self.title = movie.title
        self.isMovie = true
    }
    
    init(tvShow: TVShow) {
        self.id = tvShow.id
        self.title = tvShow.name
        self.isMovie = false
    }
    
    init(id: Int, title: String, isMovie: Bool) {
        self.id = id
        self.title = title
        self.isMovie = isMovie
    }
}

// YouTube models are now in Core/Models/YouTubeModels.swift
